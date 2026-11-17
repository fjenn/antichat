#!/usr/bin/env python3
"""Refreshes skills-index.json from its public sources and refuses to publish anything it cannot vouch for.
Python 3 standard library only; run with `python3 -I`. No key, no secret, no model.

  refresh.py --work DIR [--apply] [--summary FILE] [--skip-file-check]
  refresh.py validate [--index F] [--old F] [--files]

The refresh (weekly in the index repository, .github/workflows/refresh.yml):
  1. runs the generator into DIR/out at every source's newest commit (build-index.py --refresh --out). Curated
     skills follow their source; one that now breaks an automatic rule or matches an unsafe-text pattern is
     dropped; new upstream skills are included only when they pass the generator's automatic filters;
  2. validates the result. It is refused, and nothing changes, when
       - the generator failed;
       - the index has more than 10% fewer skills than the committed one;
       - a skill does not follow the rules the app's importer enforces (names, paths, sizes, no shell scripts,
         SKILL.md frontmatter), or points anywhere but a pinned commit of one of the source repositories;
       - any listed file, downloaded from the exact URL the app would use, does not have the listed size and
         SHA-256;
  3. with --apply, writes the new skills-index.json over the committed one (in the AntiChat source also the pinned
     commits in overrides.json). Without it this is a dry run.
The summary (Markdown: counts, new, gone, dropped, new upstream skills) goes to --summary, else to
$GITHUB_STEP_SUMMARY, and always to stdout. Exit 0 = valid (applied, or nothing to do); 1 = refused.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR = os.path.join(HERE, "build-index.py")

MAX_BYTES = 4 * 1024 * 1024       # DirectoryCatalogs.maxBytes: the app refuses a larger index
MAX_SHRINK = 0.10                 # the index may lose at most this share of its skills in one run
SKILL_SUMMARY_MAX = 60
SLUG = re.compile(r"^[a-z0-9_-]{1,64}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SKILL_NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SKILL_BASE = re.compile(r"^https://raw\.githubusercontent\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/([0-9a-f]{40})/[A-Za-z0-9._\-/]+/$")
SAFE_PATH = re.compile(r"^[A-Za-z0-9._\-/]+$")
SHELL_EXT = (".sh", ".bash", ".zsh", ".command", ".ps1", ".bat")


def generator():
    """build-index.py as a module (its paths, its frontmatter parser, its rules)."""
    sys.dont_write_bytecode = True  # no __pycache__ next to the sources
    spec = importlib.util.spec_from_file_location("build_index", GENERATOR)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw, json.loads(raw)


def source_repos():
    """The repositories a skill may come from (the app has the same list compiled in)."""
    with open(os.path.join(HERE, "overrides.json"), encoding="utf-8") as f:
        return {s["repo"] for s in json.load(f)["sources"]}


def day_ok(s):
    if not isinstance(s, str) or not DAY.match(s):
        return False
    try:
        d = datetime.date.fromisoformat(s)
    except ValueError:
        return False
    return d <= datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=1)


def categories_ok(cats, errs):
    ids = [c.get("id") for c in cats] if isinstance(cats, list) else []
    if not ids or len(set(ids)) != len(ids) or not all(
            isinstance(c.get("id"), str) and SLUG.match(c["id"]) and isinstance(c.get("title"), str)
            and 0 < len(c["title"]) <= 40 for c in cats):
        errs.append("categories: missing, repeated or malformed")
    return set(ids)


def check_index(raw, idx, old, repos):
    """Problems with the index (empty = publishable, once the files are confirmed too)."""
    errs = []
    if len(raw) > MAX_BYTES:
        errs.append(f"{len(raw)} bytes (the app refuses more than {MAX_BYTES})")
    if not day_ok(idx.get("generated")):
        errs.append(f"generated {idx.get('generated')!r} is not a day up to tomorrow")
    ids = categories_ok(idx.get("categories"), errs)
    skills = idx.get("skills") if isinstance(idx.get("skills"), list) else []
    if not skills:
        errs.append("no skills")
    seen, names = set(), set()
    for s in skills:
        where = f"skill {s.get('id')!r}"
        if not isinstance(s.get("id"), str) or not 0 < len(s["id"]) <= 140 or s["id"] in seen:
            errs.append(f"{where}: id missing, too long or repeated")
            continue
        seen.add(s["id"])
        name = s.get("name")
        if not isinstance(name, str) or not SKILL_NAME.match(name) or len(name) > 64 or name in names:
            errs.append(f"{where}: name malformed or repeated")
        names.add(name)
        if not isinstance(s.get("title"), str) or not 0 < len(s["title"]) <= 80:
            errs.append(f"{where}: title")
        summary = s.get("summary")
        if not isinstance(summary, str) or not 0 < len(summary) <= SKILL_SUMMARY_MAX or summary.endswith("."):
            errs.append(f"{where}: summary must be 1-{SKILL_SUMMARY_MAX} characters without a full stop")
        if s.get("category") not in ids:
            errs.append(f"{where}: unknown category")
        for k in ("author", "license"):
            if not isinstance(s.get(k), str) or not s[k]:
                errs.append(f"{where}: {k} missing")
        base = s.get("base") if isinstance(s.get("base"), str) else ""
        m = SKILL_BASE.match(base)
        if not m or m.group(2) != s.get("commit") or "/../" in base or "/./" in base or "//" in base[8:]:
            errs.append(f"{where}: base is not a commit-pinned raw.githubusercontent.com folder")
        elif m.group(1) not in repos:
            errs.append(f"{where}: {m.group(1)} is not one of the source repositories")
        files = s.get("files") if isinstance(s.get("files"), list) else []
        paths = [f.get("path") for f in files]
        if "SKILL.md" not in paths or len(files) > 500 or len({str(p).lower() for p in paths}) != len(paths):
            errs.append(f"{where}: no SKILL.md, too many files or a repeated path")
        total = 0
        for f in files:
            p = f.get("path")
            if not isinstance(p, str) or not SAFE_PATH.match(p) or p.startswith("/") or p.count("/") + 1 > 16 or \
                    any(part in ("", ".", "..") for part in p.split("/")):
                errs.append(f"{where}: unsafe path {p!r}")
            if p and p.lower().endswith(SHELL_EXT):
                errs.append(f"{where}: shell script {p}")
            if not isinstance(f.get("sha256"), str) or not SHA256.match(f["sha256"]) or \
                    not isinstance(f.get("size"), int) or not 0 <= f["size"] <= 10 * 1024 * 1024:
                errs.append(f"{where}: {p}: hash or size malformed")
            else:
                total += f["size"]
        if total > 2 * 1024 * 1024:
            errs.append(f"{where}: {total // 1024} KB in total (the catalogue allows 2 MB)")
    if old:
        before = len(old.get("skills", []))
        if len(skills) < before * (1 - MAX_SHRINK):
            errs.append(f"{before} -> {len(skills)} skills (more than {int(MAX_SHRINK * 100)}% fewer)")
        if day_ok(idx.get("generated")) and idx["generated"] < old.get("generated", ""):
            errs.append(f"generated {idx['generated']} is before the committed {old.get('generated')}")
    return errs


def check_files(idx, gen):
    """Downloads every listed file from the URL the app would use: size, SHA-256, and for SKILL.md the frontmatter
    rules of the app's importer and the listed name. Returns (files checked, problems)."""
    jobs = [(s["id"], s["name"], f["path"], s["base"] + f["path"], f["sha256"], f["size"])
            for s in idx["skills"] for f in s["files"]]

    def one(job):
        sid, name, path, url, digest, size = job
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "skills-index-builder"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
            except Exception as e:  # noqa: BLE001 (any failure to fetch is a failed check)
                if attempt == 2:
                    return f"skill {sid!r}: {url} could not be fetched ({e})"
                continue
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                return f"skill {sid!r}: {url} does not have the listed size and hash"
            if path == "SKILL.md":
                try:
                    fm = gen.parse_frontmatter(data.decode("utf-8"))
                    bad = gen.validate(fm)
                    if not bad and fm.get("name", "").strip() != name:
                        bad = [f"frontmatter name {fm.get('name')!r} is not the listed name"]
                except (UnicodeDecodeError, ValueError) as e:
                    bad = [str(e)]
                if bad:
                    return f"skill {sid!r}: SKILL.md breaks the importer's rules ({'; '.join(bad)})"
            return None
        return None

    with concurrent.futures.ThreadPoolExecutor(12) as ex:
        return len(jobs), [e for e in ex.map(one, jobs) if e]


def diff(old, new):
    a, b = {x["id"]: x for x in old.get("skills", [])}, {x["id"]: x for x in new.get("skills", [])}
    changed = sorted(i for i in b if i in a and a[i].get("files") != b[i].get("files"))
    return sorted(set(b) - set(a)), sorted(set(a) - set(b)), changed


def names(items, limit=40):
    return ", ".join(f"`{i}`" for i in items[:limit]) + (f" and {len(items) - limit} more" if len(items) > limit else "")


def emit(lines, path):
    text = "\n".join(lines) + "\n"
    print(text)
    path = path or os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def refresh(args):
    gen = generator()
    work = os.path.abspath(args.work)
    out = os.path.join(work, "out")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    lines = ["## Skills index refresh", ""]

    report = os.path.join(out, "report.json")
    cmd = [sys.executable, "-I", GENERATOR, "--refresh", "--out", out, "--report", report,
           "--cache", os.path.join(work, "cache")]
    print("+ " + " ".join(cmd), flush=True)
    r = subprocess.run(cmd, cwd=HERE)
    new_path = os.path.join(out, "skills-index.json")
    # Exit 1 with a report = curated skills were dropped (listed below); anything else is a failure.
    if r.returncode not in (0, 1) or not os.path.exists(report) or not os.path.exists(new_path):
        emit(lines + [f"**Refused:** the generator failed (exit {r.returncode}). Nothing was changed."], args.summary)
        return 1
    with open(report, encoding="utf-8") as f:
        rep = json.load(f)

    raw, idx = load(new_path)
    _, old = load(gen.INDEX)
    errs = check_index(raw, idx, old, source_repos())
    s_new, s_gone, s_changed = diff(old, idx)
    checked = 0
    if not errs and not args.skip_file_check:
        checked, bad = check_files(idx, gen)
        errs += bad

    auto_ids = {a["id"] for a in rep.get("auto", [])}
    lines += [
        f"- Skills: {len(old.get('skills', []))} -> **{len(idx.get('skills', []))}** (generated {idx.get('generated')})",
        f"- New in the index: {len(s_new)} {names(s_new)}",
        f"- Gone from the index: {len(s_gone)} {names(s_gone)}",
        f"- Updated to a newer upstream version: {len(s_changed)} {names(s_changed)}",
        f"- Files downloaded and compared with their size and hash: {checked}",
        "- Sources: " + ", ".join(f"`{k}` at `{v[:10]}`" for k, v in sorted(rep.get("sources", {}).items())),
        "",
        f"### Dropped by the automatic rules: {len(rep.get('dropped', []))}",
    ] + [f"- `{d['key']}`: {'; '.join(d['problems'])}" for d in rep.get("dropped", [])] + [
        "",
        f"### New upstream skills included by themselves (not reviewed by a person yet): {len(auto_ids)}",
    ] + [f"- `{a['key']}`: **{a['title']}**, {a['summary']} ({a['category']})" for a in rep.get("auto", [])] + [
        "",
        f"### New upstream skills left out: {len(rep.get('skipped_new', []))}",
    ] + [f"- `{d['key']}`: {'; '.join(d['problems'])}" for d in rep.get("skipped_new", [])[:200]]
    if errs:
        emit(lines + ["", f"**Refused: {len(errs)} problem(s). Nothing was changed or published.**"]
             + [f"- {e}" for e in errs[:60]], args.summary)
        return 1
    if idx == old:
        emit(lines + ["", "Nothing changed since the committed index."], args.summary)
        return 0
    if not args.apply:
        emit(lines + ["", "Dry run: valid; nothing was changed."], args.summary)
        return 0
    shutil.copyfile(new_path, gen.INDEX)
    if not gen.STANDALONE:  # the AntiChat source keeps its pins next to the bundled copy
        shutil.copyfile(os.path.join(out, "overrides.json"), gen.OVERRIDES)
    emit(lines + ["", "Valid: the new index was written."], args.summary)
    return 0


def validate(args):
    gen = generator()
    raw, idx = load(args.index or gen.INDEX)
    old = load(args.old)[1] if args.old else None
    errs = check_index(raw, idx, old, source_repos())
    if args.files and not errs:
        errs += check_files(idx, gen)[1]
    for e in errs:
        print(e)
    print(f"skills index: {'FAIL ' + str(len(errs)) if errs else 'ok'} ({len(idx.get('skills', []))} skills)")
    return 1 if errs else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--work", help="folder for downloads and the generator's output")
    ap.add_argument("--apply", action="store_true", help="write the new index when it is valid (default: dry run)")
    ap.add_argument("--summary", help="append the Markdown summary here (default: $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--skip-file-check", action="store_true", help="do not download the skill files to compare hashes")
    sub = ap.add_subparsers(dest="cmd")
    v = sub.add_parser("validate", help="check an index that is already written")
    v.add_argument("--index", help="default: the committed index")
    v.add_argument("--old", help="the index it replaces (for the 10% rule)")
    v.add_argument("--files", action="store_true", help="also download every skill file and compare its hash")
    args = ap.parse_args()
    if args.cmd == "validate":
        return validate(args)
    if not args.work:
        ap.error("--work is required")
    return refresh(args)


if __name__ == "__main__":
    sys.exit(main())
