#!/usr/bin/env python3
"""Builds skills-index.json, the catalogue of skills AntiChat offers in Settings > Skills.

Python 3 stdlib only. Sources, pinned commits, categories and every curated decision (which skills are in, their
title, summary, category, featured rank) live in overrides.json next to this file, so a refresh keeps them.
This file lives in two places with the same content: tools/skills/ of the AntiChat source (the original; the index
it writes there is the copy the app ships) and the root of the public index repository (the index it writes there
is the one the app downloads). tools/skills/export-index-repo.sh copies it across.

  build-index.py                 rebuild the index at the pinned commits
  build-index.py --refresh       move every source to its current HEAD, then rebuild
  build-index.py --inventory F   write a TSV of every upstream skill with the automatic checks (curation aid)
  build-index.py --check         rebuild in memory and fail if the committed index differs
  build-index.py --out DIR       write skills-index.json (and, with --refresh, overrides.json) into DIR, not
                                 next to the sources (the weekly refresh, refresh.py)
  build-index.py --report F      write what happened as JSON: the commits, every dropped skill, every new upstream
                                 skill that was included by itself and every new one that was not
  build-index.py --write-known   record every upstream skill at the pinned commits that is not in the catalogue as
                                 "known" (looked at and left out), then stop

New upstream skills. A skill listed under "skills" in overrides.json is curated: it follows its source to the newest
commit. A skill listed under "known" was looked at and left out: it stays out. A skill in neither list is new
upstream. It is included by itself only when all of this holds, and is reported either way so it can be reviewed:
  - it passes every automatic rule below and matches no unsafe-text pattern;
  - it sits in a top-level folder of its source that already has at least AUTO_MIN_FOLDER curated skills (folders
    of engineering, vendor-specific or regulatory skills have none) and is not a nested skill, a deprecated one
    or a router to other skills (`*-skills`);
  - its text shows few signs of needing a developer environment (SIGNALS: at most "auto.max_signals" hits).
Its title is its name in words, its summary the first clause of its description (at most 60 characters), its
category the most common one among the curated skills of the same folder.

Network: api.github.com (commit + recursive tree; with $GITHUB_TOKEN when set, else unauthenticated) and
codeload.github.com (one tarball per source). Tarballs are read in memory from --cache (a temp folder that is
removed unless --keep-cache).
Every file is hashed (sha256) from the tarball bytes, and its git blob sha1 is checked against the tree API, so the
hash is the hash of what raw.githubusercontent.com serves at that commit.

Automatic rules (mirrors SkillValidator.swift / SkillImporter.swift / SkillScriptPolicy.swift); a curated skill that
breaks one is dropped with a message, never silently included:
  - SKILL.md starts with YAML frontmatter; name is 1-64 chars, lowercase letters/digits/hyphens, no leading, trailing
    or double hyphen; description 1-1024 chars; compatibility <= 500. The frontmatter name is the installed folder name.
  - <= 500 files, <= 10 MB per file, <= 16 path levels, no symlinks; total <= 2 MB (catalogue rule, importer: 50 MB).
  - no shell scripts (.sh/.bash/.zsh/.command); nested skills are not part of the parent.
  - bundled Python may not open network connections or start processes (urllib.request, socket, subprocess, ...).
  - paths are plain ASCII [A-Za-z0-9._-/] so base + path is a valid URL without escaping.
  - name does not collide with a starter skill the app ships, or with an earlier catalogue entry.

The output is deterministic: the same commits and the same overrides.json give the same bytes (skills in category
order, then by title, then by id; files by path; "generated" only moves when the content changes).
"""
import argparse
import ast
import datetime
import gzip
import hashlib
from http.client import HTTPException
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.error
import warnings
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Packages", "Tools", "Sources", "AntiChatTools", "Resources")
# In the AntiChat source the index is the app's bundled resource; in the index repository it is next to this file.
STANDALONE = not os.path.isdir(RESOURCES)
OVERRIDES = os.path.join(HERE, "overrides.json")
INDEX = os.path.join(HERE if STANDALONE else RESOURCES, "skills-index.json")
STARTERS = os.path.join(RESOURCES, "StarterSkills")
UA = "skills-index-builder"
AUTO_MIN_FOLDER = 3
AUTO_MAX_SIGNALS = 5

MAX_FILES, MAX_FILE_BYTES, MAX_DEPTH, MAX_TOTAL = 500, 10 * 1024 * 1024, 16, 2 * 1024 * 1024
SHELL_EXT = (".sh", ".bash", ".zsh", ".command", ".ps1", ".bat")
SAFE_PATH = re.compile(r"^[A-Za-z0-9._\-/]+$")
ALLOWED_FIELDS = {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}

# Text that should never be in a catalogue skill: attempts to hide behaviour, exfiltrate, or switch safety off.
INJECTION = [
    r"ignore (all |any )?(previous|prior|above) (instructions|prompts)",
    r"disregard (all |any )?(previous|prior|above|your) (instructions|rules)",
    r"do not (tell|inform|reveal to|mention (this )?to) the user",
    r"without (telling|informing|notifying) the user",
    r"(reveal|print|output|leak) (your |the )?system prompt",
    r"(disable|bypass|turn off|ignore) (your |the |all )?(safety|guardrails|content polic|restrictions)",
    r"jailbreak",
    r"exfiltrat",
    r"(send|post|upload) .{0,60}(api[_ -]?key|credentials|password|token|\.env|ssh key)",
    r"curl [^\n]*\|\s*(ba)?sh",
    r"[​-‏⁠-⁤‪-‮\U000e0000-\U000e007f]",
]
INJECTION_RE = [re.compile(p, re.I) for p in INJECTION]

# Signals that a skill needs a developer environment (inventory aid only; inclusion is the curated list).
SIGNALS = {
    "shell": r"\b(bash|terminal|command line|shell script|chmod|sudo|brew install|apt(-get)? install)\b",
    "git": r"\b(git (commit|push|clone|diff|log|status|checkout)|pull request|github actions|repo(sitory)?)\b",
    "pip": r"\b(pip3? install|npm (install|run)|npx |yarn add|uv (pip|run)|docker|kubectl)\b",
    "mcp": r"(mcp__|\bMCP\b|~~[a-z])",
    "agent": r"\b(claude code|subagent|sub-agent|slash command|cursor|codex|\.claude/|CLAUDE\.md|AskUserQuestion|TodoWrite)\b",
    "pyrun": r"python3? [\w./-]*scripts?/",
}
SIGNAL_RE = {k: re.compile(v, re.I) for k, v in SIGNALS.items()}


def log(*a):
    print(*a, file=sys.stderr)


def http(url, accept=None):
    headers = {"User-Agent": UA, "Accept-Encoding": "gzip", **({"Accept": accept} if accept else {})}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):  # CI runners share addresses: unauthenticated runs out
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
                return gzip.decompress(data) if r.headers.get("Content-Encoding") == "gzip" else data
        except (OSError, HTTPException) as e:
            if attempt == 3 or (isinstance(e, urllib.error.HTTPError) and e.code in (403, 404, 429)):
                raise
            time.sleep(2 * (attempt + 1))


def head_commit(repo):
    return http(f"https://api.github.com/repos/{repo}/commits/HEAD", "application/vnd.github.sha").decode().strip()


def tree_blobs(repo, commit, cache):
    """{path: git blob sha1} from the tree API; None when the API is unavailable or the tree is truncated."""
    name = os.path.join(cache, f"{repo.replace('/', '_')}-{commit}.tree.json")
    try:
        if os.path.exists(name):
            with open(name, "rb") as f:
                t = json.loads(f.read())
        else:
            raw = http(f"https://api.github.com/repos/{repo}/git/trees/{commit}?recursive=1")
            t = json.loads(raw)
            with open(name, "wb") as f:
                f.write(raw)
    except Exception as e:  # rate limit, offline
        log(f"  tree API unavailable for {repo}: {e}")
        return None
    if t.get("truncated"):
        log(f"  tree API truncated for {repo}; blob check uses the tarball only")
        return None
    return {e["path"]: e["sha"] for e in t["tree"] if e["type"] == "blob"}


def load_tarball(repo, commit, cache):
    """{path: bytes} for regular files, plus the set of symlink paths."""
    name = os.path.join(cache, f"{repo.replace('/', '_')}-{commit}.tgz")
    if not os.path.exists(name):
        log(f"  downloading {repo}@{commit[:10]}")
        data = http(f"https://codeload.github.com/{repo}/tar.gz/{commit}")
        with open(name, "wb") as f:
            f.write(data)
    files, links = {}, set()
    with tarfile.open(name, "r:gz") as tf:
        for m in tf:
            path = m.name.split("/", 1)[1] if "/" in m.name else ""
            if not path:
                continue
            if m.issym() or m.islnk():
                links.add(path)
            elif m.isfile():
                files[path] = tf.extractfile(m).read()
    return files, links


def git_blob_sha(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


# --- frontmatter -----------------------------------------------------------------------------------------------------
# A deliberately small YAML subset. Anything it is not sure a real YAML parser (the app uses Yams) reads the same way
# raises ValueError and the skill is skipped.

def _scalar(raw, key):
    s = raw.strip()
    if not s:
        return ""
    if s[0] == '"':
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*(#.*)?$', s, re.S)
        if not m:
            raise ValueError(f"{key}: unterminated double-quoted value")
        return re.sub(r"\s*\n\s*", " ", json.loads('"' + m.group(1).replace("\n", " ") + '"')) if "\\" in m.group(1) \
            else re.sub(r"\s*\n\s*", " ", m.group(1))
    if s[0] == "'":
        m = re.match(r"^'((?:[^']|'')*)'\s*(#.*)?$", s, re.S)
        if not m:
            raise ValueError(f"{key}: unterminated single-quoted value")
        return re.sub(r"\s*\n\s*", " ", m.group(1).replace("''", "'"))
    if s[0] in "[{&*!%@`|>":
        raise ValueError(f"{key}: unsupported YAML value")
    if re.search(r":(\s|$)", s) or re.search(r"\s#", s):
        raise ValueError(f"{key}: plain value contains ': ' or ' #' (invalid or ambiguous YAML)")
    return re.sub(r"\s*\n\s*", " ", s)


def parse_frontmatter(text):
    """Returns {key: str | dict} for the top-level mapping. Raises ValueError like SkillDocument's ParseError."""
    if not text.startswith("---"):
        raise ValueError("SKILL.md must start with YAML frontmatter (---)")
    close = text.find("---", 3)
    if close < 0:
        raise ValueError("frontmatter not closed")
    block = text[3:close]
    if re.search(r"^ *\t", block, re.M):
        raise ValueError("tab indentation in frontmatter")
    lines = block.split("\n")
    out, i = {}, 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        m = re.match(r"^([A-Za-z0-9_\-]+):(?:[ ](.*))?$", line.rstrip("\r"))
        if not m:
            raise ValueError(f"unsupported frontmatter line: {line[:40]!r}")
        key, rest = m.group(1), (m.group(2) or "").strip()
        j = i + 1
        cont = []
        while j < len(lines) and (not lines[j].strip() or lines[j][0] in " \t"):
            cont.append(lines[j].rstrip("\r"))
            j += 1
        if key in out:
            raise ValueError(f"duplicate key {key}")
        bm = re.match(r"^([|>])([+-]?)\d?\s*$", rest)
        if bm:
            body = [c for c in cont]
            while body and not body[-1].strip():
                body.pop()
            indent = min((len(c) - len(c.lstrip()) for c in body if c.strip()), default=0)
            body = [c[indent:] for c in body]
            if bm.group(1) == "|":
                val = "\n".join(body)
            else:
                val, prev_blank = "", True
                for c in body:
                    if not c.strip():
                        val += "\n"
                        prev_blank = True
                    else:
                        val += ("" if prev_blank else " ") + c
                        prev_blank = False
            out[key] = val + ("" if bm.group(2) == "-" else "\n")
        elif not rest and any(c.strip() for c in cont):
            out[key] = {"_nested": "\n".join(cont)}
        else:
            out[key] = _scalar("\n".join([rest] + [c.strip() for c in cont if c.strip()]), key)
        i = j
    return out


def validate(fm):
    """SkillValidator's blocking errors for a folder named after the frontmatter name."""
    errors = []
    name = fm.get("name")
    if not isinstance(name, str) or not name.strip():
        errors.append("name missing")
    else:
        name = unicodedata.normalize("NFKC", name.strip())
        if len(name) > 64:
            errors.append("name over 64 chars")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name):
            errors.append("name not lowercase letters/digits/single hyphens")
    desc = fm.get("description")
    if not isinstance(desc, str) or not desc.strip():
        errors.append("description missing")
    elif len(desc) > 1024:
        errors.append(f"description {len(desc)} chars")
    comp = fm.get("compatibility")
    if comp is not None and (not isinstance(comp, str) or len(comp) > 500):
        errors.append("compatibility invalid")
    return errors


# --- skills ----------------------------------------------------------------------------------------------------------

NET_PROC = {"subprocess", "socket", "requests", "httpx", "aiohttp", "ftplib", "smtplib", "telnetlib", "ctypes",
            "webbrowser", "urllib.request", "http.client", "multiprocessing", "pty", "ssl"}


def risky_python(source):
    """Network or process modules a script imports; '?' when the file does not parse."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(source)
    except (SyntaxError, ValueError):
        return ["?"]
    mods = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            mods |= {a.name for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods |= {node.module} | {f"{node.module}.{a.name}" for a in node.names}
        elif isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "os" \
                and (node.attr in ("system", "popen", "fork") or node.attr.startswith(("exec", "spawn"))):
            mods.add("os." + node.attr)
    return sorted(m for m in mods if m in NET_PROC or m.split(".")[0] in NET_PROC or m.startswith("os."))


def find_skills(files):
    """{skill root: [relative paths]}; a nested skill's files belong to the nested skill only."""
    roots = sorted(os.path.dirname(p) for p in files if os.path.basename(p) == "SKILL.md" and "/" in p)
    rootset = set(roots)
    out = {r: [] for r in roots}
    for p in files:
        d = os.path.dirname(p)
        while d and d not in rootset:
            d = os.path.dirname(d)
        if d:
            out[d].append(p[len(d) + 1:])
    return out


def examine(root, rels, files, links, blobs):
    """Automatic checks for one skill. Returns (info, problems)."""
    problems = []
    md = files[root + "/SKILL.md"]
    info = {"root": root, "files": sorted(rels), "size": sum(len(files[root + "/" + r]) for r in rels)}
    try:
        text = md.decode("utf-8")
        fm = parse_frontmatter(text)
        problems += validate(fm)
    except (UnicodeDecodeError, ValueError) as e:
        text, fm = md.decode("utf-8", "replace"), {}
        problems.append(str(e))
    info["name"] = unicodedata.normalize("NFKC", fm["name"].strip()) if isinstance(fm.get("name"), str) else ""
    info["description"] = " ".join(fm["description"].split()) if isinstance(fm.get("description"), str) else ""
    info["extra_fields"] = sorted(set(fm) - ALLOWED_FIELDS)
    if len(rels) > MAX_FILES:
        problems.append(f"{len(rels)} files")
    if info["size"] > MAX_TOTAL:
        problems.append(f"{info['size'] // 1024} KB total")
    for r in rels:
        if len(files[root + "/" + r]) > MAX_FILE_BYTES:
            problems.append(f"{r} over 10 MB")
        if r.count("/") + 1 > MAX_DEPTH:
            problems.append(f"{r} too deep")
        if not SAFE_PATH.match(r) or ".." in r.split("/"):
            problems.append(f"unsafe path {r!r}")
        if r.lower().endswith(SHELL_EXT):
            problems.append(f"shell script {r}")
        if blobs is not None and blobs.get(root + "/" + r) != git_blob_sha(files[root + "/" + r]):
            problems.append(f"{r} differs from the git blob (LFS or export filter)")
    if any(l.startswith(root + "/") for l in links):
        problems.append("contains symlinks")
    if any(p.startswith(root + "/") and p.endswith("/SKILL.md") and p != root + "/SKILL.md" for p in files):
        info["nested"] = True
    alltext = ""
    for r in rels:
        if r.lower().endswith((".md", ".txt", ".py", ".json", ".yaml", ".yml", ".html", ".js", ".csv", ".xml")):
            alltext += files[root + "/" + r].decode("utf-8", "replace") + "\n"
    for r in rels:
        if r.endswith(".py"):
            risky = risky_python(files[root + "/" + r].decode("utf-8", "replace"))
            if risky:
                problems.append(f"{r} uses {', '.join(risky)}")
    info["injection"] = sorted({rx.pattern for rx in INJECTION_RE if rx.search(alltext)})
    info["signals"] = {k: len(rx.findall(alltext)) for k, rx in SIGNAL_RE.items()}
    info["hasScripts"] = any(r.startswith("scripts/") and r.endswith(".py") for r in rels)
    info["pyfiles"] = sum(r.endswith(".py") for r in rels)
    info["bodylen"] = len(text)
    return info, problems


# --- new upstream skills ---------------------------------------------------------------------------------------------

UPPER = {"ai", "api", "b2b", "b2c", "ceo", "cfo", "cmo", "coo", "cro", "crm", "cto", "cv", "faq", "hr", "kpi", "okr",
         "pdf", "pr", "qa", "roi", "seo", "sql", "ui", "ux"}
SPELLED = {"saas": "SaaS", "ios": "iOS", "macos": "macOS", "linkedin": "LinkedIn", "youtube": "YouTube"}
TRAILING = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "with", "your"}


def derive_title(name):
    return " ".join(w.upper() if w in UPPER else SPELLED.get(w, w.capitalize()) for w in name.split("-"))


def derive_summary(description, title):
    """The first clause of the description, at most 60 characters, cut at a word, without a closing full stop."""
    s = " ".join(description.split())
    s = re.sub(r"^(this skill (should be used (to|when|for)|is (used )?(to|for)|helps( you)?( to)?|provides|will)|"
               r"use (this skill )?(to|when|for)|a skill (for|that|to)|helps( you)?( to)?)\s+", "", s, flags=re.I)
    m = re.search(r"[.;:!?](\s|$)|\s(-{1,2}|[\u2013\u2014])\s|\s\(|,? (use|trigger|activate)s? (this|when|for|on|if)\b", s, re.I)
    if m and m.start() >= 12:
        s = s[:m.start()]
    if len(s) > 60:
        s = s[:61].rsplit(" ", 1)[0] if " " in s[:61] else s[:60]
    words = s.rstrip(" ,;:.!?-\u2013\u2014(").split(" ")
    while len(words) > 1 and words[-1].lower().strip(",") in TRAILING:
        words.pop()
    s = " ".join(words).rstrip(" ,;:.!?-\u2013\u2014(")
    if not re.search(r"[A-Za-z]{3}", s):
        return title
    return s[0].upper() + s[1:]


def folder_of(key):
    """`<source id>/<top-level folder>` of a skill key."""
    return "/".join(key.split("/")[:2])


def folder_categories(curated, order):
    """{folder: its most common curated category} for folders with at least AUTO_MIN_FOLDER curated skills."""
    counts = {}
    for key, cur in curated.items():
        c = counts.setdefault(folder_of(key), {})
        c[cur.get("category")] = c.get(cur.get("category"), 0) + 1
    return {f: min(c, key=lambda k: (-c[k], order.get(k, len(order)))) for f, c in counts.items()
            if sum(c.values()) >= AUTO_MIN_FOLDER}


def auto_reasons(key, info, problems, folders, max_signals):
    """Why a new upstream skill is not included by itself (empty = it is)."""
    why = list(problems)
    if info["injection"]:
        why.append("unsafe-text pattern: " + "; ".join(info["injection"]))
    if folder_of(key) not in folders:
        why.append(f"folder {folder_of(key)} has fewer than {AUTO_MIN_FOLDER} curated skills")
    if info.get("nested"):
        why.append("contains nested skills")
    if "deprecated" in (info["name"] + " " + info["description"]).lower():
        why.append("deprecated")
    if info["name"].endswith("-skills"):
        why.append("only routes to other skills")
    signals = sum(info["signals"].values())
    if signals > max_signals:
        why.append(f"needs a developer environment ({signals} signs: "
                   + ", ".join(f"{k} {v}" for k, v in sorted(info["signals"].items()) if v) + ")")
    return why


def starter_names():
    try:
        return {d for d in os.listdir(STARTERS) if os.path.isdir(os.path.join(STARTERS, d))}
    except OSError:
        return set()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--refresh", action="store_true", help="pin every source to its current HEAD first")
    ap.add_argument("--inventory", metavar="TSV", help="write every upstream skill with its checks, then stop")
    ap.add_argument("--check", action="store_true", help="fail if the committed index is not what would be built")
    ap.add_argument("--cache", help="folder for tarballs (default: a temp folder, removed afterwards)")
    ap.add_argument("--keep-cache", action="store_true")
    ap.add_argument("--out", metavar="DIR", help="write skills-index.json and overrides.json here, not into the repo")
    ap.add_argument("--report", metavar="JSON", help="write the pinned commits and the dropped skills here")
    ap.add_argument("--date", help="value for 'generated' (default: today, or the committed value when nothing changed)")
    ap.add_argument("--write-known", action="store_true",
                    help="list every upstream skill that is not curated under 'known' in overrides.json, then stop")
    args = ap.parse_args()

    with open(OVERRIDES, encoding="utf-8") as f:
        ov = json.load(f)
    cache = args.cache or tempfile.mkdtemp(prefix="skills-index-")
    os.makedirs(cache, exist_ok=True)
    category_ids = {c["id"] for c in ov["categories"]}
    reserved = starter_names() | set(ov.get("reserved_names", []))
    curated = ov["skills"]
    known = set(ov.get("known", []))
    order = {c["id"]: n for n, c in enumerate(ov["categories"])}
    folders = folder_categories(curated, order)
    max_signals = ov.get("auto", {}).get("max_signals", AUTO_MAX_SIGNALS)
    seen_names, entries, dropped, inventory, used = {}, [], [], [], set()
    candidates, upstream, auto, skipped = [], set(), [], []

    def entry(src, commit, root, info, files, title, summary, category, featured):
        return {
            "id": f"{src['id']}/{info['name']}",
            "name": info["name"],
            "title": title,
            "summary": summary,
            "category": category,
            "source": f"https://github.com/{src['repo']}/tree/{commit}/{root}",
            "author": src["author"],
            "license": src["license"],
            "commit": commit,
            "base": f"https://raw.githubusercontent.com/{src['repo']}/{commit}/{root}/",
            "files": [{"path": r, "sha256": hashlib.sha256(files[root + '/' + r]).hexdigest(),
                       "size": len(files[root + '/' + r])} for r in info["files"]],
            "hasScripts": info["hasScripts"],
            "featured": featured,
        }

    try:
        for src in ov["sources"]:
            repo = src["repo"]
            if args.refresh or not src.get("commit"):
                src["commit"] = head_commit(repo)
            commit = src["commit"]
            log(f"{src['id']}: {repo}@{commit[:10]}")
            files, links = load_tarball(repo, commit, cache)
            blobs = tree_blobs(repo, commit, cache)
            skills = find_skills(files)
            include = [re.compile(p) for p in src.get("include", [".*"])]
            for root, rels in skills.items():
                if not any(rx.match(root) for rx in include):
                    continue
                key = f"{src['id']}/{root}"
                info, problems = examine(root, rels, files, links, blobs)
                if args.inventory:
                    inventory.append((src["id"], info, problems))
                    continue
                upstream.add(key)
                cur = curated.get(key)
                if cur is None:
                    # New upstream (neither curated nor looked at before): judged after every curated skill has
                    # its name, so a newcomer can never take one.
                    if key not in known and not args.write_known:
                        why = auto_reasons(key, info, problems, folders, max_signals)
                        if why:
                            skipped.append((key, why))
                        else:
                            title = derive_title(info["name"])
                            candidates.append((key, entry(src, commit, root, info, files, title,
                                                          derive_summary(info["description"], title),
                                                          folders[folder_of(key)], None)))
                    continue
                used.add(key)
                name = info["name"]
                if info["injection"]:
                    problems.append("injection pattern: " + "; ".join(info["injection"]))
                if name in reserved:
                    problems.append("name collides with a skill the app ships")
                if name in seen_names:
                    problems.append(f"name already used by {seen_names[name]}")
                if cur.get("category") not in category_ids:
                    problems.append(f"unknown category {cur.get('category')!r}")
                summary = cur.get("summary", "")
                if not summary or len(summary) > 60 or summary.endswith("."):
                    problems.append(f"summary must be 1-60 chars without a trailing full stop ({len(summary)})")
                if not cur.get("title"):
                    problems.append("title missing")
                if problems:
                    dropped.append((key, problems))
                    continue
                seen_names[name] = key
                entries.append(entry(src, commit, root, info, files, cur["title"], summary, cur["category"],
                                     cur.get("featured")))
            del files
    finally:
        if not args.cache and not args.keep_cache:
            shutil.rmtree(cache, ignore_errors=True)

    if args.inventory:
        with open(args.inventory, "w", encoding="utf-8") as f:
            f.write("key\tname\tfiles\tkb\tscripts\tpy\tnested\tsignals\tinjection\tproblems\tdescription\n")
            for sid, info, problems in inventory:
                sig = ",".join(f"{k}{v}" for k, v in info["signals"].items() if v)
                f.write("\t".join([f"{sid}/{info['root']}", info["name"], str(len(info["files"])),
                                   str(info["size"] // 1024), str(int(info["hasScripts"])), str(info["pyfiles"]),
                                   str(int(info.get("nested", False))), sig, "|".join(info["injection"]),
                                   "|".join(problems), info["description"]]) + "\n")
        log(f"inventory: {len(inventory)} skills -> {args.inventory}")
        return 0

    if args.write_known:
        ov["known"] = sorted(upstream - set(curated))
        with open(OVERRIDES, "w", encoding="utf-8") as f:
            json.dump(ov, f, ensure_ascii=False, indent=1)
            f.write("\n")
        log(f"known: {len(ov['known'])} upstream skills that are not in the catalogue")
        return 0

    for key, e in sorted(candidates, key=lambda c: c[0]):
        if e["name"] in reserved or e["name"] in seen_names:
            skipped.append((key, [f"name {e['name']} is already taken"]))
            continue
        seen_names[e["name"]] = key
        entries.append(e)
        auto.append({"key": key, "id": e["id"], "title": e["title"], "summary": e["summary"], "category": e["category"]})
    skipped.sort()
    for a in auto:
        log(f"NEW {a['key']}: included as {a['title']!r} ({a['category']}): {a['summary']}")
    for key, why in skipped:
        log(f"NEW, not included: {key}: {'; '.join(why)}")

    for key in sorted(set(curated) - used):
        dropped.append((key, ["not found upstream at the pinned commit"]))
    for key, problems in dropped:
        log(f"DROPPED {key}: {'; '.join(problems)}")

    entries.sort(key=lambda e: (order[e["category"]], e["title"].lower(), e["id"]))
    generated = args.date or datetime.date.today().isoformat()
    try:
        with open(INDEX, encoding="utf-8") as f:
            old = json.load(f)
        if old.get("categories") == ov["categories"] and old.get("skills") == entries and not args.date:
            generated = old["generated"]
    except (OSError, ValueError):
        old = None
    index = {"generated": generated, "categories": ov["categories"], "skills": entries}
    out = json.dumps(index, ensure_ascii=False, separators=(",", ":")) + "\n"

    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump({"sources": {s_["id"]: s_["commit"] for s_ in ov["sources"]}, "skills": len(entries),
                       "dropped": [{"key": k, "problems": p} for k, p in dropped], "auto": auto,
                       "skipped_new": [{"key": k, "problems": p} for k, p in skipped]},
                      f, ensure_ascii=False, indent=1)
    if args.out:
        os.makedirs(args.out, exist_ok=True)
    if args.check:
        ok = old == index
        log("index is up to date" if ok else "index is STALE: run build-index.py")
        return 0 if ok and not dropped else 1
    if args.refresh:
        with open(os.path.join(args.out, "overrides.json") if args.out else OVERRIDES, "w", encoding="utf-8") as f:
            json.dump(ov, f, ensure_ascii=False, indent=1)
            f.write("\n")
    with open(os.path.join(args.out, "skills-index.json") if args.out else INDEX, "w", encoding="utf-8") as f:
        f.write(out)
    per = {}
    for e in entries:
        per[e["category"]] = per.get(e["category"], 0) + 1
    log(f"wrote {len(entries)} skills ({len(out) // 1024} KB), {len(dropped)} dropped: "
        + ", ".join(f"{k} {v}" for k, v in sorted(per.items(), key=lambda kv: order[kv[0]])))
    return 1 if dropped else 0


if __name__ == "__main__":
    sys.exit(main())
