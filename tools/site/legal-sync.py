#!/usr/bin/env python3
"""AT-217 (M10.T06; R-217 AC1/AC2): one source for the legal pages, two places.
Copies site/src/content/docs/legal/* (plus acceptable-use) into App/AntiChat/Resources/Legal/<slug>.md for the
in-app Legal view (offline): MDX imports dropped, hosting values filled from Config/Hosting.json, the form replaced
by the address. Front matter (title, version, updated) is kept. Then checks: all pages present in both with equal
versions; Evil Mode terms state the single child-safety block (D-006) and 18+; abuse page has "72 hours", the
address and (on the site) the form; privacy has the aggregate-counts sentence.
  --check   no writing; exit 1 on drift or a failed content rule.  `python3 -I tools/site/legal-sync.py [--check]`"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site/src/content/docs"
APP = ROOT / "App/AntiChat/Resources/Legal"
PAGES = ["terms", "privacy", "evil-mode-terms", "abuse", "security", "licenses", "model-licenses"]


def source(slug: str) -> Path:
    for ext in (".md", ".mdx"):
        if (SITE / "legal" / f"{slug}{ext}").exists():
            return SITE / "legal" / f"{slug}{ext}"
    return SITE / f"{slug}.md"


def to_app(text: str, h: dict) -> str:
    text = re.sub(r"^import .*\n", "", text, flags=re.M)
    text = re.sub(r"<form.*?</form>\n*(The form[^\n]*\n)?", "", text, flags=re.S)
    for k in ("abuseEmail", "securityEmail", "supportEmail"):
        text = text.replace("{hosting." + k + "}", h[k])
    text = re.sub(r":::caution\[Draft\]\n(.*?)\n:::", r"> **Draft.** \1", text, flags=re.S)
    text = re.sub(r"\]\((/[^)]*)\)", lambda m: "](" + h["siteURL"].rstrip("/") + m.group(1) + ")", text)
    return re.sub(r"^sidebar: .*\n", "", text, flags=re.M)


def front(text: str) -> dict:
    m = re.match(r"---\n(.*?)\n---", text, re.S)
    return dict(re.findall(r'^(\w+): "?([^"\n]*)"?$', m.group(1), re.M)) if m else {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    h = json.loads((ROOT / "Config/Hosting.json").read_text())
    bad: list[str] = []
    APP.mkdir(parents=True, exist_ok=True)
    for slug in PAGES + ["acceptable-use"]:
        src = source(slug).read_text()
        want = to_app(src, h)
        dst = APP / f"{slug}.md"
        if a.check:
            if not dst.exists() or dst.read_text() != want:
                bad.append(f"App/AntiChat/Resources/Legal/{slug}.md differs from the site page (run legal-sync.py)")
        else:
            dst.write_text(want)
        fm = front(src)
        if not fm.get("version") or not fm.get("updated"):
            bad.append(f"{slug}: front matter needs version + updated (R-217 AC2)")
    evil = source("evil-mode-terms").read_text()
    if "sexual content involving minors" not in evil or "18" not in evil or "only filter" not in evil:
        bad.append("evil-mode-terms: must state 18+ and the single child-safety block (D-006)")
    abuse = source("abuse").read_text()
    if "72 hours" not in abuse or "<form" not in abuse or "mailto:" not in abuse:
        bad.append("abuse: needs '72 hours', a mailto: and the client-side form")
    if "aggregate download counts" not in source("privacy").read_text():
        bad.append("privacy: lacks the aggregate-counts sentence")
    for b in bad:
        print(b)
    print(f"legal-sync: {'ok' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
