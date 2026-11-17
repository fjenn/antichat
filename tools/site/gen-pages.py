#!/usr/bin/env python3
"""Generated site pages (M10.T05; R-304 AC1). `python3 -I`; stdlib only.
  changelog.md  ← notes/<ver>.md, newest first (gen-changelog)
  help/uninstall.md ← App/AntiChat/Resources/Help/uninstall.md (the in-app page is the source; copy-help)
--check exits 1 when a committed page is stale."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "site/src/content/docs"


def vkey(p: Path):
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", p.stem))


def changelog() -> str:
    out = ["---", "title: Changelog", "description: What changed in each AntiChat release.", "---", ""]
    for n in sorted((ROOT / "notes").glob("*.md"), key=vkey, reverse=True):
        lines = n.read_text().splitlines()
        title = lines[0].lstrip("# ").strip() if lines and lines[0].startswith("#") else n.stem
        out += [f"## {title}", ""] + [l for l in lines[1:] if l.strip()] + [""]
    return "\n".join(out).rstrip() + "\n"


def uninstall() -> str:
    src = (ROOT / "App/AntiChat/Resources/Help/uninstall.md").read_text()
    body = re.sub(r"^# .*\n+", "", src, count=1)
    return ("---\ntitle: How to uninstall AntiChat\nsidebar: {order: 15}\n---\n"
            "<!-- GENERATED from App/AntiChat/Resources/Help/uninstall.md by tools/site/gen-pages.py -->\n\n" + body)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    bad = 0
    for rel, text in (("changelog.md", changelog()), ("help/uninstall.md", uninstall())):
        p = DOCS / rel
        if a.check:
            if not p.exists() or p.read_text() != text:
                print(f"gen-pages: site/src/content/docs/{rel} is stale"); bad = 1
        else:
            p.write_text(text)
    print(f"gen-pages: {'ok' if not bad else 'stale'}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
