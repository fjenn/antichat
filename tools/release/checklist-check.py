#!/usr/bin/env python3
"""AT-305 check 7 (M10.T08; R-305 AC3): the release checklist has the 20 items of ci-release §8, covers key
custody (links KEYS.md), the certificate-revocation contingency (new certificate, same EdDSA key, website download,
data outside the bundle survives), and orders the clean-Mac smoke (12) before publishing the appcast (14).
`python3 -I tools/release/checklist-check.py [CHECKLIST.md]`"""
from __future__ import annotations

import re
import sys
from pathlib import Path

p = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("CHECKLIST.md"))
t = p.read_text()
items = {int(m.group(1)): m.group(2) for m in re.finditer(r"^(\d+)\. \[[ x]\] (.+)$", t, re.M)}
bad = []
if sorted(items) != list(range(1, 21)):
    bad.append(f"items are {sorted(items)}, expected 1–20")
if "KEYS.md" not in t or "custody" not in t.lower():
    bad.append("no key-custody item linking KEYS.md")
rev = t[t.find("revocation"):] if "revocation" in t.lower() else ""
for need in ("new Developer ID", "same", "website", "survives"):
    if need.lower() not in rev.lower():
        bad.append(f"revocation contingency lacks '{need}'")
pos = {n: t.find(f"\n{n}. [") for n in (12, 13, 14)}
if not (0 < pos[12] < pos[14] and 0 < pos[13] < pos[14]):
    bad.append("clean-Mac smoke (12) and update smoke (13) must come before publishing (14)")
if "VM" not in items.get(12, ""):
    bad.append("item 12 must be the clean-Mac VM smoke")
for b in bad:
    print(b)
print(f"checklist-check: {'ok' if not bad else f'{len(bad)} problem(s)'}")
sys.exit(1 if bad else 0)
