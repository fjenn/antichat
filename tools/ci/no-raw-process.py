#!/usr/bin/env python3
"""No raw process spawns (M7.T13, D-026 note 6; R-265, R-259). Run with `python3 -I`.

Every new child process in AntiChat goes through `AntiChatPlatform/ProcessLauncher.swift` (swift-subprocess 1.0.2,
`spawnCount`). This lint scans our Swift code under Packages/ and App/ for `Process(`, `posix_spawn(` / `posix_spawnp(`,
`Subprocess.run` and `NSTask` (comments ignored) and fails on any hit outside ProcessLauncher.swift and the files listed
in `tools/ci/no-raw-process-allow.txt` (seeded with the launch sites that existed at M7.T13's start, each with a one-line
justification). Vendored donors (Vendor/) are not our code and are covered by the vendored allow-list.

Allow-list lines: `<path or fnmatch glob relative to the repo root>  # <justification>`; a line without a
justification is an error, and so is an entry that matches no file (stale).
"""
from __future__ import annotations

import fnmatch
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOW = ROOT / "tools/ci/no-raw-process-allow.txt"
LAUNCHER = "Packages/Platform/Sources/AntiChatPlatform/ProcessLauncher.swift"
SCAN = ("Packages", "App")
PATTERN = re.compile(r"\bProcess\(|\bposix_spawnp?\(|\bSubprocess\.run\b|\bNSTask\b")


def code_part(line: str) -> str:
    """The line without a trailing `//` comment (string literals with `//` are rare enough to ignore here)."""
    s = line.lstrip()
    if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
        return ""
    i = line.find("//")
    return line if i < 0 else line[:i]


def load_allow(path: Path) -> tuple[list[tuple[str, str]], list[str]]:
    entries, errors = [], []
    if not path.exists():
        return entries, [f"{path.relative_to(ROOT)} missing"]
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        pat, _, why = line.partition("#")
        pat, why = pat.strip(), why.strip()
        if not why:
            errors.append(f"{path.name}:{n}: '{pat}' has no justification")
        entries.append((pat, why))
    return entries, errors


def scan(root: Path) -> list[tuple[str, int, str]]:
    hits = []
    for top in SCAN:
        base = root / top
        if not base.exists():
            continue
        for f in sorted(base.rglob("*.swift")):
            rel = f.relative_to(root).as_posix()
            if "/.build/" in rel or rel.startswith("Packages/.build"):
                continue
            for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if PATTERN.search(code_part(line)):
                    hits.append((rel, i, line.strip()))
    return hits


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else ROOT
    allow_path = root / "tools/ci/no-raw-process-allow.txt"
    entries, errors = load_allow(allow_path)
    hits = scan(root)
    used: set[str] = set()
    bad = []
    for rel, i, text in hits:
        if rel == LAUNCHER:
            continue
        match = next((p for p, _ in entries if fnmatch.fnmatch(rel, p)), None)
        if match:
            used.add(match)
        else:
            bad.append(f"{rel}:{i}: raw process spawn outside ProcessLauncher: {text}")
    for p, _ in entries:
        if p not in used:
            errors.append(f"{allow_path.name}: stale entry '{p}' (no raw spawn there any more): remove it")
    for e in errors + bad:
        print(e)
    if errors or bad:
        print(f"no-raw-process: FAIL ({len(bad)} unlisted spawn(s), {len(errors)} allow-list error(s)); use ProcessLauncher")
        return 1
    print(f"no-raw-process: ok ({len(hits)} spawn sites, all in ProcessLauncher or allow-listed; {len(entries)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
