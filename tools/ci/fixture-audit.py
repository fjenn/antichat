#!/usr/bin/env python3
"""R-285 AC7 (M4.T03): no private calibration content is tracked. Stdlib only, `python3 -I`.

Fails (exit 1) if any tracked path — in this repo or in the `fixtures` submodule — lies under a `private/`
directory, or if `fixtures/private` is tracked as anything but an untracked symlink target. The lawful proxy sets
live only in ~/AntiChatPrivateFixtures on the runner (Packages/ChildSafetyCheck/METHOD.md).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def tracked(repo: Path) -> list[str]:
    p = subprocess.run(["git", "-C", str(repo), "ls-files"], capture_output=True, text=True)
    return p.stdout.splitlines() if p.returncode == 0 else []


def main() -> int:
    errs = [f"tracked private content: {f}" for f in tracked(ROOT) if f.startswith("fixtures/private") or "/private/" in f"/{f}"]
    sub = ROOT / "fixtures"
    if (sub / ".git").exists():
        errs += [f"tracked private content: fixtures/{f}" for f in tracked(sub) if f.startswith("private/") or "/private/" in f"/{f}"]
    for e in errs:
        print(e)
    print(f"fixture-audit: {'FAIL ' + str(len(errs)) if errs else 'ok'} (R-285 AC7: private calibration sets never tracked)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
