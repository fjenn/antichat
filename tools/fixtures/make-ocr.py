#!/usr/bin/env python3
"""Render the synthetic OCR / vision fixture set fixtures/images/ocr/ (M0.T04 step 1; used by T04 K-NEW-MOD-5,
T09 and M6). Deterministic: seed 20261030, Pillow's built-in scalable font (no system fonts), PNG output.

50 items: 20 text/document pages, 10 receipts, 10 bar charts, 10 UI screenshots of invented apps.
answers.jsonl rows: {"file", "question", "answer", "normaliser": "exact"|"number"|"contains"}.
All content is invented here and released CC0 (see SOURCES.md written next to the images).

Usage: tools/.venv/bin/python -I tools/fixtures/make-ocr.py --out fixtures/images/ocr
"""
from __future__ import annotations

import argparse
import json
import os
import random

from PIL import Image, ImageDraw, ImageFont

SEED = 20261030
WORDS = ("harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel canal "
         "ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar willow").split()
SHOPS = ["Lantern Grocers", "Quarry Bakehouse", "Thistle Pharmacy", "Weir Hardware", "Orchard Market"]
ITEMS = ["Apples", "Bread", "Milk", "Coffee", "Rice", "Soap", "Batteries", "Tea", "Cheese", "Eggs", "Pasta", "Honey"]
APPS = ["Tidely", "Pewterpad", "Kilnboard", "Weirmail", "Loomcal"]


def font(size: int):
    return ImageFont.load_default(size=size)


def doc(rng: random.Random, i: int, out: str, rows: list):
    img = Image.new("RGB", (1024, 768), "white")
    d = ImageDraw.Draw(img)
    title = f"{rng.choice(WORDS).title()} {rng.choice(WORDS).title()} Report"
    code = f"{rng.choice('ABCDEFGHJKLMNPQRSTUVWXYZ')}{rng.randint(100, 999)}-{rng.randint(10, 99)}"
    d.text((60, 50), title, fill="black", font=font(40))
    d.text((60, 110), f"Reference: {code}", fill="black", font=font(26))
    y = 170
    for _ in range(9):
        line = " ".join(rng.choice(WORDS) for _ in range(rng.randint(7, 11))).capitalize() + "."
        d.text((60, y), line, fill="black", font=font(24))
        y += 52
    f = f"doc-{i:02d}.png"
    img.save(os.path.join(out, f))
    rows.append({"file": f, "question": "What is the reference code on this page?", "answer": code, "normaliser": "exact"})


def receipt(rng: random.Random, i: int, out: str, rows: list):
    img = Image.new("RGB", (600, 900), (250, 248, 240))
    d = ImageDraw.Draw(img)
    shop = rng.choice(SHOPS)
    d.text((40, 40), shop, fill="black", font=font(36))
    d.text((40, 90), f"Receipt #{rng.randint(1000, 9999)}", fill="black", font=font(22))
    y, total = 150, 0
    for it in rng.sample(ITEMS, rng.randint(3, 7)):
        cents = rng.randint(99, 1999)
        total += cents
        d.text((40, y), it, fill="black", font=font(26))
        d.text((420, y), f"{cents / 100:.2f}", fill="black", font=font(26))
        y += 48
    d.line((40, y + 10, 560, y + 10), fill="black", width=2)
    d.text((40, y + 30), "TOTAL", fill="black", font=font(30))
    d.text((420, y + 30), f"{total / 100:.2f}", fill="black", font=font(30))
    f = f"receipt-{i:02d}.png"
    img.save(os.path.join(out, f))
    rows.append({"file": f, "question": "What is the total amount on this receipt?", "answer": f"{total / 100:.2f}", "normaliser": "number"})


def chart(rng: random.Random, i: int, out: str, rows: list):
    img = Image.new("RGB", (900, 600), "white")
    d = ImageDraw.Draw(img)
    labels = rng.sample(["North", "South", "East", "West", "Harbour", "Quarry", "Meadow"], 5)
    vals = [rng.randint(10, 95) for _ in labels]
    d.text((40, 20), f"Visitors by area ({rng.randint(2001, 2025)})", fill="black", font=font(30))
    base, x = 520, 80
    for lab, v in zip(labels, vals):
        h = v * 4
        d.rectangle((x, base - h, x + 100, base), fill=(70, 110, 180))
        d.text((x + 30, base - h - 32), str(v), fill="black", font=font(22))
        d.text((x + 5, base + 12), lab, fill="black", font=font(22))
        x += 160
    best = labels[vals.index(max(vals))]
    f = f"chart-{i:02d}.png"
    img.save(os.path.join(out, f))
    rows.append({"file": f, "question": "Which area has the highest bar?", "answer": best, "normaliser": "contains"})


def ui(rng: random.Random, i: int, out: str, rows: list):
    img = Image.new("RGB", (1280, 800), (236, 236, 240))
    d = ImageDraw.Draw(img)
    app = rng.choice(APPS)
    d.rectangle((0, 0, 1280, 60), fill=(40, 40, 48))
    d.text((24, 14), app, fill="white", font=font(30))
    d.rectangle((0, 60, 260, 800), fill=(222, 222, 228))
    for j, w in enumerate(rng.sample(WORDS, 6)):
        d.text((24, 90 + j * 50), w.title(), fill="black", font=font(24))
    btn = rng.choice(["Save draft", "Send now", "Archive all", "Start timer", "Export week"])
    d.rounded_rectangle((900, 700, 1220, 770), radius=14, fill=(60, 120, 220))
    d.text((930, 718), btn, fill="white", font=font(28))
    d.text((300, 100), f"{rng.choice(WORDS).title()} settings", fill="black", font=font(34))
    f = f"ui-{i:02d}.png"
    img.save(os.path.join(out, f))
    rows.append({"file": f, "question": "What does the blue button in the bottom right say?", "answer": btn, "normaliser": "exact"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/images/ocr")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(SEED)
    rows: list = []
    for i in range(20):
        doc(rng, i, a.out, rows)
    for i in range(10):
        receipt(rng, i, a.out, rows)
    for i in range(10):
        chart(rng, i, a.out, rows)
    for i in range(10):
        ui(rng, i, a.out, rows)
    with open(os.path.join(a.out, "answers.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    with open(os.path.join(a.out, "SOURCES.md"), "w") as f:
        f.write("# images/ocr — sources\n\n"
                "Origin: rendered by `tools/fixtures/make-ocr.py` (seed 20261030, Pillow 13.0.0 built-in font). "
                "All text, shops, apps and numbers are invented. Licence: CC0-1.0.\n\n"
                "50 items: 20 `doc-*` (reference code), 10 `receipt-*` (total), 10 `chart-*` (highest bar), "
                "10 `ui-*` (button label). Questions and answers in `answers.jsonl` "
                "(`normaliser`: exact | number | contains). Used by M0.T04 (K-NEW-MOD-5 vision), M0.T09, M6.\n")
    print(f"[ok] {len(rows)} items -> {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
