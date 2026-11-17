#!/usr/bin/env python3
"""make audit + release build/preflight: developer test modes never ship. Run with `python3 -I`.

Owner decision: the release app carries no developer test mode. Bench mode (`-Bench`), the Spike UI, probes, harness
windows, scripted inputs, fakes, spies, dev model lists and every launch option, defaults key or environment variable
that changes behaviour for testing only are compiled under `#if DEBUG || ANTICHAT_PERF_HARNESS` (Debug builds and the
never-shipped perf-harness build of tools/perf/build-perf.sh and tools/bench.sh; tools/ci/perfharness-guard.py keeps
that flag out of releases). This guard keeps it so.

Source checks (always), over shipping Swift (App/ and Packages/*/Sources, tests excluded):
  1. Developer-only files (DEV_FILES globs: bench, probes, visual-QA drivers, dev models, spike, harness windows,
     install test hooks, scripted inputs) are gated as a whole: the first line of code is the gate and its `#endif`
     is the last.
  2. Outside a gated region, shipping code does not
       - read the launch arguments (`CommandLine.arguments`, `ProcessInfo…arguments`),
       - read the process environment (`ProcessInfo…environment`, `getenv`),
       - name an `ANTICHAT_*` variable or a `-LaunchOption` literal,
       - read a UserDefaults key written as a string literal (`….bool(forKey: "SpikeUI")`; settings use Keys.swift),
     except for the lines listed in tools/ci/dev-modes-allow.txt, each with the reason it is legitimately in a
     release (`<path>  <token>  # <reason>`; token = the literal name, or `arguments` / `environment`). An entry
     without a reason or one that matches nothing (stale) is an error.
  3. No marker of check 4 is written outside a gated region.
Artefact check:
  4. --app APP (tools/release/build-release.sh before signing, tools/release/preflight.py): no executable in the
     bundle carries a developer-mode marker (MARKERS: the bench marker and names that exist only in gated code).
Stdlib only; exit 1 on any violation. --root points at another tree (self-tests).
"""
from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from pathlib import Path

GATE = "#if DEBUG || ANTICHAT_PERF_HARNESS"
ALLOW = "tools/ci/dev-modes-allow.txt"
# A condition that makes a region developer-only. ANTICHAT_UI_TESTING is defined by no configuration (r241-audit).
DEV_CONDITION = re.compile(r"\b(?:DEBUG|ANTICHAT_PERF_HARNESS|ANTICHAT_UI_TESTING)\b")
NEGATED = re.compile(r"!\s*\(?\s*(?:DEBUG|ANTICHAT_PERF_HARNESS|ANTICHAT_UI_TESTING)\b")

# Command-line tools of the repo that no app bundle contains (their own executables).
NOT_IN_THE_APP = ("Packages/ChildSafetyCheck/Sources/csc-bench/",)

DEV_FILES = (
    "App/AntiChat/Bench*.swift", "App/AntiChat/*Probe*.swift", "App/AntiChat/VisualQA*.swift",
    "App/AntiChat/DevModels.swift", "App/AntiChat/SessionLedger.swift",
    "Packages/UI/Sources/AntiChatUI/Spike/*.swift", "Packages/UI/Sources/*/*/*Harness.swift",
    "Packages/UI/Sources/*/*/*TestHooks.swift",
    "Packages/Engines/Sources/AntiChatEngines/Voice/ScriptedVoice.swift",
    "Packages/Engines/Sources/AntiChatEngines/Jobs/Scripted*.swift",
    "Packages/Tools/Sources/AntiChatTools/MCP/Scripted*.swift",
)

# Byte markers of developer-only code: each is longer than 15 bytes (a shorter Swift literal is stored inline, not as
# a C string) and occurs in shipping Swift only inside a gated region (check 3), so a release binary has none.
MARKERS = (
    "AntiChatBenchMode-NeverInRelease",  # BenchMode.marker
    "UseScriptedImageEngine",            # LaunchOptions.Key (the launch-option parser)
    "FakeInstalledPacks",                # LaunchOptions.Key
    "ANTICHAT_DEV_CONTAINER",            # the dev container option
    "ANTICHAT_PERF_QUIT_AFTER",          # PerfRecorder's environment hooks
    "-RendererLiveSelectable",           # a raw launch argument in the renderer
    "-SkillImportFile",                  # a raw launch argument in Settings › Skills
)

READS = (
    ("arguments", re.compile(r"\bCommandLine\.arguments\b|\bprocessInfo\.arguments\b|\bCommandLine\.argc\b")),
    ("environment", re.compile(r"\bprocessInfo\.environment\b|\binfo\.environment\b|\bgetenv\(")),
)
LITERALS = (
    re.compile(r'"(ANTICHAT_[A-Z0-9_]+)"'),
    re.compile(r'"(-[A-Z][A-Za-z0-9]{3,})"'),
    re.compile(r'\.(?:bool|string|integer|double|float|object|array|stringArray|dictionary|data|url|set|removeObject)'
               r'\((?:[^()"]*,\s*)?forKey:\s*"([^"]+)"'),
)


def code_part(line: str) -> str:
    s = line.strip()
    if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
        return ""
    return re.sub(r"\s//.*$", "", line)


def is_dev_condition(directive: str) -> bool:
    c = directive.split("//", 1)[0]
    return bool(DEV_CONDITION.search(c)) and not NEGATED.search(c)


def regions(text: str):
    """Yields (line number, line, inside a developer-only region) for every line that is not a directive."""
    stack: list[bool] = []
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("#if"):
            stack.append(is_dev_condition(s))
        elif s.startswith("#elseif") and stack:
            stack[-1] = is_dev_condition(s)
        elif s.startswith("#else") and stack:
            stack[-1] = False  # the other branch of a developer condition (or of anything else) ships
        elif s.startswith("#endif") and stack:
            stack.pop()
        else:
            yield i, line, any(stack)


def shipping_swift(root: Path):
    for top in ("App", "Packages"):
        base = root / top
        for f in sorted(base.rglob("*.swift")) if base.is_dir() else ():
            parts = f.relative_to(root).parts
            if any(p.endswith("Tests") or p.startswith(".") or p in ("build", "Vendor", "Tools") for p in parts):
                continue
            if top == "Packages" and "Sources" not in parts:
                continue
            if any(f.relative_to(root).as_posix().startswith(x) for x in NOT_IN_THE_APP):
                continue
            yield f


def whole_file_gated(text: str) -> bool:
    code = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("//")]
    if not code or code[0] != GATE or code[-1] != "#endif":
        return False
    depth = 0
    for n, l in enumerate(code):
        if l.startswith("#if"):
            depth += 1
        elif l.startswith("#endif"):
            depth -= 1
            if depth == 0 and n != len(code) - 1:
                return False  # the gate closed before the end of the file
    return depth == 0


def load_allow(root: Path) -> tuple[list[tuple[str, str]], list[str]]:
    path = root / ALLOW
    entries, errors = [], []
    if not path.exists():
        return entries, [f"{ALLOW} missing"]
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        head, _, why = line.partition("#")
        fields = head.split()
        if len(fields) != 2:
            errors.append(f"{ALLOW}:{n}: expected `<path>  <token>  # <reason>`")
            continue
        if not why.strip():
            errors.append(f"{ALLOW}:{n}: '{fields[0]} {fields[1]}' has no reason")
        entries.append((fields[0], fields[1]))
    return entries, errors


def tokens(code: str) -> list[str]:
    out = [name for name, pat in READS if pat.search(code)]
    for pat in LITERALS:
        out += pat.findall(code)
    return out


def source_checks(root: Path) -> list[str]:
    entries, errors = load_allow(root)
    used: set[tuple[str, str]] = set()
    for f in shipping_swift(root):
        rel = f.relative_to(root).as_posix()
        text = f.read_text(encoding="utf-8", errors="replace")
        if any(fnmatch.fnmatch(rel, g) for g in DEV_FILES) and not whole_file_gated(text):
            errors.append(f"{rel}: a developer-only file must be wholly inside `{GATE}` … `#endif`")
        for i, line, dev in regions(text):
            if dev:
                continue
            code = code_part(line)
            for m in MARKERS:
                if m in code:
                    errors.append(f"{rel}:{i}: developer-mode marker `{m}` outside `{GATE}`")
            for tok in dict.fromkeys(tokens(code)):
                if (rel, tok) in entries:
                    used.add((rel, tok))
                elif tok not in MARKERS:
                    errors.append(f"{rel}:{i}: `{tok}` is read outside `{GATE}`: gate it (developer-only) or list it in "
                                  f"{ALLOW} with the reason a release needs it: {line.strip()[:120]}")
    for e in entries:
        if e not in used:
            errors.append(f"{ALLOW}: stale entry '{e[0]} {e[1]}' (nothing there any more): remove it")
    return errors


def app_checks(app: Path) -> list[str]:
    contents = app / "Contents"
    if not contents.is_dir():
        return [f"{app}: not an app bundle"]
    errors: list[str] = []
    needles = [m.encode() for m in MARKERS]
    for sub in ("MacOS", "Frameworks", "XPCServices", "PlugIns", "Helpers"):
        d = contents / sub
        for f in sorted(d.rglob("*")) if d.is_dir() else ():
            if not f.is_file() or f.is_symlink():
                continue
            with f.open("rb") as fh:
                if fh.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe"):
                    continue  # executables only: resources and scripts are not compiled Swift
                data = fh.read()
            for n in needles:
                if n in data:
                    errors.append(f"{app}/{f.relative_to(app).as_posix()}: carries `{n.decode()}` "
                                  "(a developer test mode is compiled in: not a release build)")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--app", help="check a built AntiChat.app: a release build carries no developer test mode")
    ap.add_argument("--app-only", action="store_true", help="with --app: skip the source checks")
    a = ap.parse_args()
    root = Path(a.root)
    errors = [] if (a.app and a.app_only) else source_checks(root)
    if a.app:
        errors += app_checks(Path(a.app))
    for e in errors:
        print(f"dev-modes-guard: {e}", file=sys.stderr)
    print(f"dev-modes-guard: {'FAIL' if errors else 'ok'} ({len(errors)} problem(s))")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
