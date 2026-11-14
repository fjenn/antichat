#!/usr/bin/env python3
"""AT-226 AC3 (M8.T11): the bundled Help page `App/AntiChat/Resources/Help/uninstall.md` (also the website Uninstall
page source, M10.T05) describes both ways, lists every documented path of `tools/ci/antichat-paths.txt` verbatim, the
moved-Models-folder note, the Keychain note and the Time Machine sentence. Run with `python3 -I`; exit 1 on a miss."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "App/AntiChat/Resources/Help/uninstall.md"
PATHS = ROOT / "tools/ci/antichat-paths.txt"
MUST = [
    "Uninstall AntiChat…",  # way 1: the menu item
    "Remove it by hand",  # way 2
    "Drag **AntiChat** from Applications to the Trash",
    "moved the Models folder",
    "Keychain items named app.antichat.* can be deleted in Keychain Access.",
    "The Models folder is never included in Time Machine backups.",
    "Chats in older Time Machine backups remain the user's to delete",
]


def main() -> int:
    text = PAGE.read_text()
    misses = [m for m in MUST if m not in text]
    for p in PATHS.read_text().splitlines():
        if p and not p.startswith("#") and not p.startswith("<") and f"`{p}`" not in text:
            misses.append(p)
    for m in misses:
        print(f"{PAGE.relative_to(ROOT)}: missing {m!r}", file=sys.stderr)
    if not misses:
        print(f"uninstall-page-check: ok ({PAGE.relative_to(ROOT)})")
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main())
