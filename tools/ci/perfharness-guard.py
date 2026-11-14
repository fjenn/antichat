#!/usr/bin/env python3
"""make audit + release preflight (M9.T05): the perf-harness build flag ANTICHAT_PERF_HARNESS (Debug test hooks in an
optimized build, `make build-perf`) never reaches a release, try-out or Developer ID build. Same shape as
devfeed-guard.py (RC review P2-8).

Source checks (always):
  1. ANTICHAT_PERF_HARNESS is added to SWIFT_ACTIVE_COMPILATION_CONDITIONS by exactly one line, in
     tools/perf/build-perf.sh, and set by no other build input (project.yml, Makefile, xcconfigs, release scripts).
  2. In shipping Swift (App/, Packages/ minus tests) the flag appears only as `#if DEBUG || ANTICHAT_PERF_HARNESS`,
     except in BuildFlavor.swift, which owns the marker and the flavor flags.
  2b. D-006: the ChildSafetyCheck gate (MediaOutputGate, MediaJobRunner, the ChildSafetyCheck package) carries no
     DEBUG / perf-harness condition, so the perf build runs exactly the Release gate on every Photo/Video output
     (only the detector manifest's pinning differs, in SafetyStatus / BenchMode+Image; r241-audit rule 2c).
Artefact checks:
  3. --app APP: no executable code in the bundle carries the perf-harness marker (BuildFlavor.perfHarnessMarker).
     preflight.py runs `--app build/release/AntiChat.app`.
  4. Without --app: build/release/AntiChat.app and build/tryout/AntiChat.app, where present, carry no marker.
Stdlib only; exit 1 on any violation. --root points at another tree (self-tests).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FLAG = "ANTICHAT_PERF_HARNESS"
BUILD_PERF = "tools/perf/build-perf.sh"
FLAVOR = "Packages/Foundation/Sources/AntiChatFoundation/Debug/BuildFlavor.swift"
MARKER = "AntiChatPerfHarnessBuild-M9T05"
GATE = f"#if DEBUG || {FLAG}"
FLAG_LINE = f"'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) {FLAG}' build | $beautify"
# Files that may name the flag at all (besides gated Swift sources): the build script, this guard and its tests,
# the audits that read the gate, the perf runner that checks the build, and the docs/Makefile comments.
# D-006: compiled identically in every build (ANTICHAT_UI_TESTING, defined by no configuration, is r241-audit's).
GATE_SOURCES = ("Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift",
                "Packages/Engines/Sources/AntiChatEngines/Jobs/MediaJobRunner.swift", "Packages/ChildSafetyCheck/Sources")
ALLOWED = {BUILD_PERF, FLAVOR, "tools/ci/perfharness-guard.py", "tools/ci/tests/test_perfharness_guard.py",
           "tools/ci/r241-audit.py", "tools/perf/run.py", "tools/perf/t05.py", "tools/ci/tests/test_perf.py", "Makefile"}


def comment_free_sh(line: str) -> str:
    return "" if line.lstrip().startswith("#") else line


def source_checks(root: Path) -> list[str]:
    errors: list[str] = []
    bp = root / BUILD_PERF
    lines = [l.strip() for l in bp.read_text(encoding="utf-8").splitlines() if FLAG in comment_free_sh(l)] if bp.exists() else []
    if lines != [FLAG_LINE]:
        errors.append(f"{BUILD_PERF}: {FLAG} must be added by exactly `{FLAG_LINE}` (found {lines})")
    mk = (root / "Makefile").read_text(encoding="utf-8") if (root / "Makefile").exists() else ""
    for i, l in enumerate(mk.splitlines(), 1):
        if FLAG in comment_free_sh(l):
            errors.append(f"Makefile:{i}: sets {FLAG} (only {BUILD_PERF} may)")
    for g in GATE_SOURCES:
        base = root / g
        for f in ([base] if base.is_file() else base.rglob("*.swift") if base.is_dir() else []):
            for i, l in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                code = l.split("//", 1)[0]
                if re.search(r"#(?:if|elseif)\b.*\b(?:DEBUG|" + FLAG + r")\b", code):
                    errors.append(f"{f.relative_to(root).as_posix()}:{i}: D-006: the safety gate must not depend on "
                                  f"DEBUG/{FLAG} (found `{code.strip()}`)")
    for f in scan_files(root):
        rel = f.relative_to(root).as_posix()
        if rel in ALLOWED:
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        if FLAG not in text:
            continue
        if rel.endswith(".swift"):
            for i, l in enumerate(text.splitlines(), 1):
                code = l.split("//", 1)[0].strip()
                if FLAG in code and code != GATE:
                    errors.append(f"{rel}:{i}: {FLAG} only as `{GATE}` (found `{code}`)")
            continue
        errors.append(f"{rel}: names {FLAG} (only {sorted(ALLOWED)} and `{GATE}` in Swift sources may)")
    return errors


def scan_files(root: Path):
    """Shipping Swift (App/, Packages/ minus tests and build dirs) and every build input that could set the flag."""
    for top in ("App", "Packages"):
        for f in (root / top).rglob("*.swift") if (root / top).is_dir() else ():
            parts = f.relative_to(root).parts
            if any(p.endswith("Tests") or p.startswith(".") or p == "build" for p in parts):
                continue
            yield f
    for pat in ("project.yml", "Package.swift", "Config/**/*", "App/**/*.xcconfig", "tools/release/*", "tools/perf/*.sh",
                "tools/ci/*.sh", "AntiChat.xcodeproj/project.pbxproj"):
        for f in root.glob(pat):
            if f.is_file():
                yield f


def app_checks(app: Path) -> list[str]:
    contents = app / "Contents"
    if not contents.is_dir():
        return [f"{app}: not an app bundle"]
    errors: list[str] = []
    needle = MARKER.encode()
    for sub in ("MacOS", "Frameworks", "XPCServices", "PlugIns", "Helpers"):
        d = contents / sub
        if d.is_dir():
            for f in d.rglob("*"):
                if f.is_file() and not f.is_symlink() and needle in f.read_bytes():
                    errors.append(f"{app}/{f.relative_to(app).as_posix()}: carries the perf-harness marker ({FLAG} compiled in)")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--app", help="check a built AntiChat.app (a release/try-out build must not be a perf build)")
    a = ap.parse_args()
    root = Path(a.root)
    errors = source_checks(root)
    if a.app:
        errors += app_checks(Path(a.app))
    else:
        for rel in ("build/release/AntiChat.app", "build/tryout/AntiChat.app"):
            if (root / rel).is_dir():
                errors += app_checks(root / rel)
    for e in errors:
        print(f"perfharness-guard: {e}", file=sys.stderr)
    print(f"perfharness-guard: {'FAIL' if errors else 'ok'} ({len(errors)} problem(s))")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
