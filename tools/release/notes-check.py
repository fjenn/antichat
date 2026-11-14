#!/usr/bin/env python3
"""Checklist item 7 (M10.T07/T08): notes/<ver>.md exists with ≥ 1 bullet; notes/<ver>.json has version == <ver>,
3–5 What's-new items (icon, title, body), booleans critical/prerelease. `python3 -I tools/release/notes-check.py VER`"""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "notes"
ver = sys.argv[1]
bad = []
md, js = root / f"{ver}.md", root / f"{ver}.json"
if not md.exists() or not any(l.startswith("- ") for l in md.read_text().splitlines()):
    bad.append(f"{md.name}: missing or without bullet points")
if not js.exists():
    bad.append(f"{js.name}: missing")
else:
    d = json.loads(js.read_text())
    if d.get("version") != ver:
        bad.append(f"{js.name}: version {d.get('version')!r} != {ver}")
    items = d.get("items", [])
    if not 3 <= len(items) <= 5 or not all({"icon", "title", "body"} <= set(i) for i in items):
        bad.append(f"{js.name}: needs 3–5 items with icon/title/body")
    for k in ("critical", "prerelease"):
        if not isinstance(d.get(k), bool):
            bad.append(f"{js.name}: {k} must be true/false")
for b in bad:
    print(b)
print(f"notes-check {ver}: {'ok' if not bad else f'{len(bad)} problem(s)'}")
sys.exit(1 if bad else 0)
