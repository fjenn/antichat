#!/usr/bin/env python3
"""R-241 "no other filter" audit (test-strategy §9, D-005/D-006; M1.T02). Run with `python3 -I`.

Fails (exit 1, `file:line: rule N: …`) if any of these holds:
  0. Packages/ChildSafetyCheck/README.md is missing, lacks one of the M4.T01 headings (README_HEADINGS), or does
     not name the single category and the single call site.
  1. Import rule: `import ChildSafetyCheck` (any form) in any tracked file other than
     Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift (the package's own sources, tests and
     csc-bench are inside the package and exempt); or a SwiftPM target other than AntiChatEngines depends on the
     ChildSafetyCheck product; or project.yml names it.
  2. Call-site rule (grep mode until M4 re-enables symbol-graph mode, M1.T02 fallback): a `ChildSafetyCheck`
     API reference outside MediaOutputGate.swift, or `MediaOutputGate`'s `evaluate…(` called from any file other
     than MediaJobRunner.swift (the media job result path, M4).
  2c. Unpinned detectors (M4 review P1-1, D-006 "no launch argument changes the gate"): the self-hashing detector
     manifest (`SafetyManifestResolver.resolveUnpinned` / `devModelsRoot`) is referenced only inside `#if DEBUG`
     (or a test target), so no Release code path (a `-Bench` lane, a launch option) can build one.
  3. Pattern rule: outside Packages/ChildSafetyCheck/ and the allow-list, Swift/TS/JS/Python/JSON/YAML (+ the
     rendered system-prompt snapshots of the Harness tests) contain a moderation/filter identifier, a regex word
     list, a moderation API, a text/image safety classifier id in a catalog (other than the `csc-*` entries),
     a logit-bias/token-ban parameter, or a safety clause of a prompt template.
  4. Prompt rule: when the Harness snapshots exist (M1.T14), the Normal system prompt carries no AntiChat-added
     safety/behaviour clause and the Evil prompt = Normal + exactly one added line (the catalog tone sentence).
  5. Path rule: runtime trace in the integration suite (MediaOutputGate.trace; R241PathTests) — not a static
     check; this script only verifies the trace hook exists.
  3b. (M7.T15) Markdown that reaches a prompt (starter skills' SKILL.md, catalog/*.md) gets the rule-3 patterns, and
     the M7 roots (Search, MCP, Composio, Skills, relay/, catalog/search-*.yaml, catalog/mcp-curated.yaml) must not use
     content-safety vocabulary (`safety`, `adult`, `nsfw`, `porn…`, `obscen…`) outside the allow-list: SafeSearch.swift
     is the only search code that mentions safety (a user option, off by default, passed as a URL parameter).
  4b. (M7.T15) When the full-prompt snapshots exist (`prompt-full-{normal,evil}.txt`: system prompt + tool block + the
     volatile tail with the skill manifest and a pre-loaded skill + a web result + an MCP result), Evil = Normal + the
     tone sentence only, and every Normal line with a behaviour word (never/always/must/do not/refuse/decline/avoid/
     ignore) is allow-listed (citation format, provenance labels, tool-use mechanics — no content policy).
`--full` (AT-241 c1) also writes build/at/AT-241/audit.json: the scanned roots per flow (chat, voice, search,
connector, skill, file; a missing or empty root fails), files scanned, findings, runtime.
Allow-list: tools/ci/r241-allowlist.yml (path glob, match regex, justification, reviewer; CODEOWNERS: lead).
`--root DIR` audits another tree (used by tools/ci/tests). `--binary PATH` also scans a built helper with `nm -gU`.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_common import ROOT, allowed, load_allowlist, repo_files, validate_allowlist  # noqa: E402

GATE = "Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift"
CSC_DIR = "Packages/ChildSafetyCheck/"
# M4.T01 step 2 (D-006): the README's required sections, matched exactly.
README_HEADINGS = ("## What it does", "## The single category it blocks", "## Where it is called",
                   "## What it never checks", "## Models", "## Fails closed", "## No setting", "## Testing")
SCAN_EXT = (".swift", ".ts", ".tsx", ".js", ".mjs", ".py", ".json", ".yml", ".yaml")
# 3b: Markdown that becomes prompt text (skills) or catalog documentation.
MD_ROOTS = ("Packages/Tools/Sources/AntiChatTools/Resources/StarterSkills/", "catalog/")
M7_ROOTS = ("Packages/Tools/Sources/AntiChatTools/Search/", "Packages/Tools/Sources/AntiChatTools/MCP/",
            "Packages/Tools/Sources/AntiChatTools/Composio/", "Packages/Tools/Sources/AntiChatTools/Skills/",
            "Packages/Tools/Sources/AntiChatTools/Resources/StarterSkills/", "relay/src/", "relay/api/",
            "catalog/search-engines.yaml", "catalog/mcp-curated.yaml")
SAFETY_VOCAB = re.compile(r"(?i)\b(?:safety|adult|nsfw|porn\w*|obscen\w*)\b")
BEHAVIOUR = re.compile(r"(?i)\b(?:never|always|must|do not|don't|refus\w*|declin\w*|avoid|ignore)\b")
# AT-241 c1: the flows the full audit must cover (every root must exist and hold scanned files).
FLOW_ROOTS = {
    "chat": ["Packages/Harness/Sources/AntiChatHarness/Turn/", "Packages/Harness/Sources/AntiChatHarness/Prompt/",
             "Packages/Harness/Sources/AntiChatHarness/Mode/", "Packages/Harness/Sources/AntiChatHarness/ToolLoop/",
             "Packages/UI/Sources/AntiChatUI/Conversation/"],
    "voice": ["Packages/Engines/Sources/AntiChatEngines/STT/", "Packages/Engines/Sources/AntiChatEngines/TTS/",
              "Packages/Engines/Sources/AntiChatEngines/Voice/", "Packages/Harness/Sources/AntiChatHarness/Voice/"],
    "search": ["Packages/Tools/Sources/AntiChatTools/Search/", "Packages/Harness/Sources/AntiChatHarness/Tools/WebSearchTools.swift",
               "Packages/Harness/Sources/AntiChatHarness/Prompt/WebResultsBlock.swift", "catalog/search-engines.yaml"],
    "connector": ["Packages/Tools/Sources/AntiChatTools/MCP/", "Packages/Tools/Sources/AntiChatTools/Composio/",
                  "Packages/Harness/Sources/AntiChatHarness/Tools/MCPTools.swift", "relay/src/", "catalog/mcp-curated.yaml"],
    "skill": ["Packages/Tools/Sources/AntiChatTools/Skills/", "Packages/Tools/Sources/AntiChatTools/Resources/StarterSkills/",
              "Packages/Harness/Sources/AntiChatHarness/Tools/SkillTools.swift"],
    "file": ["Packages/Tools/Sources/AntiChatTools/FileTools/", "Packages/Tools/Sources/AntiChatTools/FileOut/",
             "Packages/FileToolsHost/Sources/", "Packages/Knowledge/Sources/", "Packages/Harness/Sources/AntiChatHarness/Context/",
             "Packages/Harness/Sources/AntiChatHarness/Attachments/", "App/FileToolsHelper/"],
}
SNAPSHOT_DIR = "Packages/Harness/Tests"
IMPORT_CSC = re.compile(r"^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?ChildSafetyCheck\b")
CSC_REF = re.compile(r"\bChildSafetyCheck\s*[.(]")
GATE_CALL = re.compile(r"\b\w*[Gg]ate\w*\s*\.\s*(?:evaluate|check(?:Preview|Result|Video))\w*\s*\(|"
                       r"\bMediaOutputGate\b[^\n]*\.(?:evaluate|check(?:Preview|Result|Video))\w*\s*\(")
# M4 review: any call of a gate check method (whatever the receiver is called: an alias such as `let g = gate` then
# `g.checkResult(…)` escaped GATE_CALL) outside MediaJobRunner.swift / the gate itself; `func` declarations excluded.
ANY_CHECK_CALL = re.compile(r"(?<!func )\bcheck(?:Preview|Result|Video)\s*\(")
# M4.T03 step 4: the forced-verdict test seam compiles only under this condition, which no Debug/Release config defines.
UI_TESTING_COND = "ANTICHAT_UI_TESTING"
TEST_DIR = re.compile(r"(^|/)(Tests|UITests|IntegrationTests)/")
# M4 review P1-1: the self-hashing (unpinned) detector manifest; DEBUG-only.
UNPINNED = re.compile(r"\b(?:resolveUnpinned|devModelsRoot)\b")
# M9.T05: the optimized perf-harness build (`make build-perf`) compiles the Debug test hooks too; it never ships
# (tools/ci/perfharness-guard.py fails any release/devid build or build script that sets ANTICHAT_PERF_HARNESS).
DEBUG_CONDS = {"DEBUG", "DEBUG || ANTICHAT_PERF_HARNESS"}


def debug_only_lines(lines: list[str]) -> set[int]:
    """1-based line numbers compiled only in DEBUG (or the never-shipped perf harness): the first branch of `#if DEBUG`
    / `#if DEBUG || ANTICHAT_PERF_HARNESS`, or the `#else` branch of
    `#if !DEBUG`. Other conditions are neutral (the enclosing state carries through)."""
    out: set[int] = set()
    stack: list[list] = []  # [condition, in_else]
    for i, raw in enumerate(lines, 1):
        t = raw.strip()
        if t.startswith("#if"):
            stack.append([t[3:].strip(), False])
            continue
        if t.startswith(("#elseif", "#else")) and stack:
            stack[-1][1] = True
            if t.startswith("#elseif"):
                stack[-1][0] = ""  # a further condition: neutral
            continue
        if t.startswith("#endif") and stack:
            stack.pop()
            continue
        if any((c.split("//")[0].strip() in DEBUG_CONDS and not e) or (c == "!DEBUG" and e) for c, e in stack):
            out.add(i)
    return out

# Rule 3 patterns: (id, regex). Matched on code lines (comments included: a "refuse" in a comment of our
# own code is still reviewed; vendored comments are allow-listed by path).
CONTENT = r"(?:content|prompts?|requests?|images?|outputs?|text|messages?|topics?|words?|replies|reply|responses?|answers?)"
PATTERNS: list[tuple[str, re.Pattern]] = [
    ("filter identifier", re.compile(
        r"(?i)(moderat(?:e|ion|or)\w*|block-?list\w*|deny-?list\w*|profan\w*|toxic\w*|jail-?break\w*|"
        r"\bisSafe\b|\bisUnsafe\b|policy[ _-]?violation\w*|content[ _-]?filter\w*|(?<!child)safety[ _-]?(?:filter|check(?:er)?|classifier|guard)\w*|"
        r"\bnsfw\w*|\bshould_?refuse\b|\brefus(?:e|al)\w*?(?:detector|check|classif|filter|policy|template)\w*)")),
    # "refuse" / "unsafe" / "harmful" in the CONTENT sense only (technical "refuse a redirect", "unsafe path",
    # Swift's Unsafe* APIs are not filters).
    ("refuse/unsafe/harmful (content sense)", re.compile(
        r"(?i)\b(?:refus(?:e|es|ed|al|als|ing)|unsafe|harmful|offensive|dangerous)[ _-]?" + CONTENT + r"\b")),
    ("moderation API", re.compile(
        r"(?i)(/moderations\b|perspectiveapi|commentanalyzer|llama[ _-]?guard|shield[ _-]?gemma|nemo[ _-]?guardrails|"
        r"granite[ _-]?guardian|omni-moderation)")),
    ("logit-bias / token ban", re.compile(
        r"(?i)(logit[ _-]?bias|banned[ _-]?tokens?|bad[ _-]?words[ _-]?ids|suppress[ _-]?tokens|token[ _-]?ban|"
        r"forbidden[ _-]?words)")),
    ("prompt safety clause", re.compile(
        r"(?i)(as an ai\b|i can(?:no|')t (?:help|assist)|ethical guidelines|inappropriate content|"
        r"(?:must|should|always) (?:refuse|decline)(?: to)? (?:answer|help|assist|respond|engage|requests?|questions?|anything)\b|refuse to (?:answer|help|assist|respond|engage)|"
        r"be (?:safe|respectful|harmless)\b|do not (?:produce|generate|write) (?:harmful|offensive|explicit))")),
    ("regex word list", re.compile(
        r"(?:Regex|NSRegularExpression|re\.compile|#/|/\(\?i\))[^\n]*\\b\(?(?:[A-Za-z]{3,}\|){5,}[A-Za-z]{3,}")),
]
CLASSIFIER_ID = re.compile(r"(?i)(nsfw|safety|guard|toxic|moderation|detox|harm)")
CATALOG_FILES = ("catalog/", "tools/dev/models-m0.json")


def git_lines(f: Path):
    return f.read_text(encoding="utf-8", errors="replace").splitlines()


def _pinned(root: Path, entries: list[dict]) -> tuple[list[dict], list[str]]:
    """An entry with `sha256` covers exactly one file (no glob) and only while that file hashes to the pin
    (vendored third-party code: a re-vendor must be re-signed). A mismatched or missing file drops the entry
    and is an error, so the allowance can't silently widen to a different file content."""
    import hashlib

    keep, errs = [], []
    for e in entries:
        pin = e.get("sha256")
        if not pin:
            keep.append(e)
            continue
        if any(c in e["path"] for c in "*?["):
            errs.append(f"r241-allowlist.yml: {e['path']}: a sha256-pinned entry must name one exact file")
            continue
        f = root / e["path"]
        got = hashlib.sha256(f.read_bytes()).hexdigest() if f.is_file() else "missing"
        if got != pin.lower():
            errs.append(f"r241-allowlist.yml: {e['path']}: sha256 {got} != pinned {pin} (re-vendored? re-sign the entry)")
            continue
        keep.append(e)
    return keep, errs


def check(root: Path, allow_path: Path | None = None, scanned: list[str] | None = None) -> list[str]:
    errs: list[str] = []
    allow_path = allow_path or root / "tools/ci/r241-allowlist.yml"
    entries = load_allowlist(allow_path) if allow_path.exists() else []
    errs += validate_allowlist(entries, ("path", "match", "justification", "reviewer"), "r241-allowlist.yml")
    entries, pin_errs = _pinned(root, entries)
    errs += pin_errs

    # 0. README
    readme = root / CSC_DIR / "README.md"
    if not readme.exists():
        errs.append(f"{CSC_DIR}README.md: rule 0: missing (D-006)")
    else:
        t = readme.read_text(encoding="utf-8")
        heads = {ln.strip() for ln in t.splitlines() if ln.startswith("## ")}
        for h in README_HEADINGS:
            if h not in heads:
                errs.append(f"{CSC_DIR}README.md: rule 0: missing heading '{h}' (M4.T01 step 2)")
        if "sexual content involving minors" not in t or "MediaOutputGate.swift" not in t:
            errs.append(f"{CSC_DIR}README.md: rule 0: must name the single category and the single call site")

    swift = repo_files(root, (".swift",))
    # 1. import rule (whole tree incl. Vendor/ and App/)
    for f in swift:
        r = str(f.relative_to(root))
        if r == GATE or r.startswith(CSC_DIR):
            continue
        for i, line in enumerate(git_lines(f), 1):
            if IMPORT_CSC.match(line):
                errs.append(f"{r}:{i}: rule 1: imports ChildSafetyCheck (only {GATE} may)")
    pkg = root / "Package.swift"
    if pkg.exists():
        # every target block that names the ChildSafetyCheck product must be AntiChatEngines
        text = pkg.read_text(encoding="utf-8")
        for m in re.finditer(r'product\(name:\s*"ChildSafetyCheck"', text):
            head = text[:m.start()]
            owner = re.findall(r'module\("(\w+)"|name:\s*"(\w+)",\s*\n?\s*(?:dependencies|path)', head)
            last = next((a or b for a, b in reversed(owner)), "?")
            if last not in ("Engines", "AntiChatEngines"):
                ln = head.count("\n") + 1
                errs.append(f"Package.swift:{ln}: rule 1: target {last} depends on ChildSafetyCheck (only AntiChatEngines may)")
    proj = root / "project.yml"
    if proj.exists():
        for i, line in enumerate(git_lines(proj), 1):
            if "ChildSafetyCheck" in line and not line.lstrip().startswith("#"):
                errs.append(f"project.yml:{i}: rule 1: app/helper targets must not name ChildSafetyCheck directly")

    # 2. call-site rule (grep mode)
    for f in swift:
        r = str(f.relative_to(root))
        if r == GATE or r.startswith(CSC_DIR):
            continue
        for i, line in enumerate(git_lines(f), 1):
            code = line.split("//", 1)[0]
            if CSC_REF.search(code) and not allowed(entries, r, line):
                errs.append(f"{r}:{i}: rule 2: ChildSafetyCheck API referenced outside MediaOutputGate.swift")
            flagged = False
            if "MediaOutputGate" in code or ("Gate" in code and ("evaluate" in code or "check" in code)):
                if GATE_CALL.search(code) and not r.endswith("/MediaJobRunner.swift") and not TEST_DIR.search(r) \
                        and not allowed(entries, r, line):
                    errs.append(f"{r}:{i}: rule 2: media gate evaluated outside MediaJobRunner.emitPreview/emitResult/emitVideoResult")
                    flagged = True
            if not flagged and ANY_CHECK_CALL.search(code) and not r.endswith("/MediaJobRunner.swift") \
                    and not TEST_DIR.search(r) and not allowed(entries, r, line):
                errs.append(f"{r}:{i}: rule 2: gate check call outside MediaJobRunner.emitPreview/emitResult/emitVideoResult")

    # 2b. the UI-testing seam: the condition may appear only in the gate (as `#if`) and never be defined by a
    # Debug/Release build setting or a package swiftSettings define (M4.T03 step 4, R-285 AC6).
    for f in swift:
        r = str(f.relative_to(root))
        for i2, line in enumerate(git_lines(f), 1):
            if UI_TESTING_COND in line.split("//", 1)[0] and r != GATE and not TEST_DIR.search(r):
                errs.append(f"{r}:{i2}: rule 2: {UI_TESTING_COND} used outside MediaOutputGate.swift")
    for cfg in [root / "project.yml", *sorted(root.glob("Packages/*/Package.swift")), root / "Package.swift"]:
        if cfg.exists():
            for i2, line in enumerate(git_lines(cfg), 1):
                if UI_TESTING_COND in line and not line.lstrip().startswith(("#", "//")):
                    errs.append(f"{cfg.relative_to(root)}:{i2}: rule 2: {UI_TESTING_COND} defined in a shipped build configuration")

    # 2c. the unpinned (self-hashing) detector manifest compiles in DEBUG only (M4 review P1-1).
    for f in swift:
        r = str(f.relative_to(root))
        if TEST_DIR.search(r):
            continue
        lines = git_lines(f)
        if not any(UNPINNED.search(ln.split("//", 1)[0]) for ln in lines):
            continue
        dbg = debug_only_lines(lines)
        for i2, line in enumerate(lines, 1):
            if UNPINNED.search(line.split("//", 1)[0]) and i2 not in dbg:
                errs.append(f"{r}:{i2}: rule 2c: unpinned detector manifest outside #if DEBUG (Release must use the signed catalog's pins)")

    # 3. pattern rule
    files = repo_files(root, SCAN_EXT)
    files += [f for f in repo_files(root, (".md",)) if str(f.relative_to(root)).startswith(MD_ROOTS)]
    snaps = [p for p in (root / SNAPSHOT_DIR).rglob("*") if p.is_file() and "__Snapshots__" in p.parts] \
        if (root / SNAPSHOT_DIR).is_dir() else []
    for f in files + snaps:
        r = str(f.relative_to(root))
        if r.startswith((CSC_DIR, "Vendor/.upstream/", "docs/", "fixtures/", "build/")) or r == "tools/ci/r241-audit.py" \
                or r.startswith("tools/ci/tests/") or r == "tools/ci/r241-allowlist.yml":
            continue
        if scanned is not None:
            scanned.append(r)
        lines = git_lines(f)
        for i, line in enumerate(lines, 1):
            if r.startswith(M7_ROOTS) and SAFETY_VOCAB.search(line) and not allowed(entries, r, line):
                errs.append(f"{r}:{i}: rule 3b: content-safety vocabulary in an M7 root: {line.strip()[:120]}")
                continue
            if r.startswith(CATALOG_FILES) and re.search(r'"repo"|repo:', line) and CLASSIFIER_ID.search(line):
                # only the ChildSafetyCheck detector entries (keys csc-*) may name a safety classifier
                window = "\n".join(lines[max(0, i - 4):i])
                if re.search(r'"?csc-[\w-]+"?\s*:|\bkey:\s*csc-[\w-]+', window):
                    continue
                if not allowed(entries, r, line):
                    errs.append(f"{r}:{i}: rule 3: safety classifier id outside the csc-* entries")
                    continue
            for pid, rx in PATTERNS:
                if rx.search(line) and not allowed(entries, r, line):
                    errs.append(f"{r}:{i}: rule 3: {pid}: {line.strip()[:120]}")
                    break

    # 4. prompt rule (active once M1.T14 writes the snapshots)
    sdir = root / SNAPSHOT_DIR
    normal = next(iter(sorted(sdir.rglob("system-prompt-normal*.txt"))), None) if sdir.is_dir() else None
    evil = next(iter(sorted(sdir.rglob("system-prompt-evil*.txt"))), None) if sdir.is_dir() else None
    if normal and evil:
        n = [ln for ln in normal.read_text(encoding="utf-8").splitlines() if ln.strip()]
        e = [ln for ln in evil.read_text(encoding="utf-8").splitlines() if ln.strip()]
        extra = [ln for ln in e if ln not in n]
        if [ln for ln in n if ln not in e] or len(extra) != 1:
            errs.append(f"{evil.relative_to(root)}: rule 4: Evil prompt must be Normal + exactly one tone sentence "
                        f"(found {len(extra)} added lines)")

    # 4b. full-prompt rule (M7.T15): web results, skill manifest + body, MCP tools present
    fnormal = next(iter(sorted(sdir.rglob("prompt-full-normal*.txt"))), None) if sdir.is_dir() else None
    fevil = next(iter(sorted(sdir.rglob("prompt-full-evil*.txt"))), None) if sdir.is_dir() else None
    if fnormal and fevil:
        n = [ln for ln in fnormal.read_text(encoding="utf-8").splitlines() if ln.strip()]
        e = [ln for ln in fevil.read_text(encoding="utf-8").splitlines() if ln.strip()]
        extra = [ln for ln in e if ln not in n]
        if [ln for ln in n if ln not in e] or len(extra) != 1:
            errs.append(f"{fevil.relative_to(root)}: rule 4b: Evil full prompt must be Normal + exactly one tone sentence "
                        f"(found {len(extra)} added lines)")
        rn = str(fnormal.relative_to(root))
        for i, ln in enumerate(fnormal.read_text(encoding="utf-8").splitlines(), 1):
            if BEHAVIOUR.search(ln) and not allowed(entries, rn, ln):
                errs.append(f"{rn}:{i}: rule 4b: AntiChat-added behaviour clause not on the allow-list: {ln.strip()[:120]}")
    elif (root / "Packages/Tools/Sources/AntiChatTools/Search").is_dir():
        errs.append(f"{SNAPSHOT_DIR}: rule 4b: prompt-full-{{normal,evil}}.txt snapshots missing (PromptSnapshotTests, M7.T15)")

    # 5. path rule hook
    gate = root / GATE
    if gate.exists() and "trace" not in gate.read_text(encoding="utf-8"):
        errs.append(f"{GATE}: rule 5: tracing hook (MediaOutputGate.trace) missing")
    return errs


def scan_binary(path: Path) -> list[str]:
    """M4.T03 step 4 / R-285 AC6: no ForcedVerdict symbol in a shipped (Debug/Release) helper binary."""
    import subprocess
    if not path.exists():
        return [f"{path}: rule 2: binary missing (build it first)"]
    out = subprocess.run(["nm", "-gU", str(path)], capture_output=True, text=True).stdout
    n = sum("ForcedVerdict" in ln for ln in out.splitlines())
    return [f"{path}: rule 2: {n} ForcedVerdict symbol(s) in a shipped binary"] if n else []


def full_report(root: Path, scanned: list[str], errs: list[str], seconds: float) -> list[str]:
    """AT-241 c1 evidence: which roots of each flow were scanned (a root that is gone or empty fails)."""
    import datetime
    import json
    out, flows = [], {}
    for flow, roots in FLOW_ROOTS.items():
        rows = []
        for r in roots:
            n = sum(1 for f in scanned if f == r or f.startswith(r))
            rows.append({"root": r, "files": n})
            if n == 0:
                out.append(f"{r}: --full: {flow} root missing or holds no scanned file (AT-241 c1 scope)")
        flows[flow] = rows
    report = {"date": datetime.date.today().isoformat(), "rules": ["0", "1", "2", "2b", "3", "3b", "4", "4b", "5 (hook)"],
              "modes": "Normal and Evil (rules 4/4b compare both modes' snapshots; no scanned code takes the mode as input "
                       "for a content decision)",
              "files_scanned": len(set(scanned)), "flows": flows, "findings": errs + out, "seconds": round(seconds, 2),
              "result": "pass" if not (errs or out) else "fail"}
    dest = root / "build/at/AT-241"
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "audit.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--full", action="store_true", help="AT-241 c1: also write build/at/AT-241/audit.json (roots per flow)")
    ap.add_argument("--binary", action="append", default=[],
                    help="built helper binary to scan with `nm -gU` for the forced-verdict seam (must be 0 symbols)")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    import time
    t0 = time.monotonic()
    scanned: list[str] = []
    errs = check(root, scanned=scanned) + [e for b in a.binary for e in scan_binary(Path(b))]
    if a.full:
        errs += full_report(root, scanned, errs, time.monotonic() - t0)
    for e in errs:
        print(e)
    print(f"r241-audit: {'FAIL ' + str(len(errs)) if errs else 'ok'} (rule 2 grep mode; rule 4 "
          f"{'active' if list((root / SNAPSHOT_DIR).rglob('system-prompt-normal*.txt')) else 'inactive until M1.T14'}; "
          f"rule 5 = integration R241PathTests)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
