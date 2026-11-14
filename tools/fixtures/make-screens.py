#!/usr/bin/env python3
"""AT-237 fixture (M6.T06): fixtures/images/needs-ocr-10/ — 10 images whose answer is text in the image (5 receipts,
5 app screenshots of invented apps), + questions.jsonl {file, question, gold}. Seed 20261108, Pillow built-in
scalable font, invented content, CC0.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-screens.py --out fixtures/images/needs-ocr-10
"""
from __future__ import annotations

import argparse
import json
import os
import random

from PIL import Image, ImageDraw, ImageFont

SEED = 20261108
SHOPS = ["Lantern Grocers", "Quarry Bakehouse", "Thistle Pharmacy", "Weir Hardware", "Orchard Market"]
ITEMS = ["Apples", "Bread", "Milk", "Coffee", "Rice", "Soap", "Tea", "Cheese", "Eggs", "Honey"]
APPS = ["Tidely", "Pewterpad", "Kilnboard", "Weirmail", "Loomcal"]


def font(px):
    return ImageFont.load_default(size=px)


def code(rng):
    return f"{rng.choice('ABCDEFGHJKLMNPQRSTUVWXYZ')}{rng.choice('ABCDEFGHJKLMNPQRSTUVWXYZ')}{rng.randint(10, 99)}-{rng.randint(1000, 9999)}"


def receipt(rng, i, out):
    img = Image.new("RGB", (640, 900), "white")
    d = ImageDraw.Draw(img)
    shop = SHOPS[i % len(SHOPS)]
    order = code(rng)
    d.text((40, 40), shop, fill="black", font=font(36))
    d.text((40, 100), f"Order {order}", fill="black", font=font(26))
    y, total = 170, 0.0
    for it in rng.sample(ITEMS, 5):
        p = rng.randint(100, 2000) / 100
        total += p
        d.text((40, y), it, fill="black", font=font(24))
        d.text((480, y), f"{p:.2f}", fill="black", font=font(24))
        y += 46
    d.text((40, y + 30), "TOTAL", fill="black", font=font(28))
    d.text((480, y + 30), f"{total:.2f}", fill="black", font=font(28))
    f = f"receipt-{i:02d}.png"
    img.save(os.path.join(out, f))
    return {"file": f, "question": "What is the order number on this receipt?", "gold": order}


def screen(rng, i, out):
    img = Image.new("RGB", (1024, 700), (244, 245, 247))
    d = ImageDraw.Draw(img)
    app = APPS[i % len(APPS)]
    d.rectangle([0, 0, 1024, 60], fill=(40, 44, 52))
    d.text((24, 14), app, fill="white", font=font(30))
    key = code(rng)
    d.text((60, 140), "Your activation key", fill=(30, 30, 30), font=font(28))
    d.rectangle([60, 190, 600, 260], outline=(120, 120, 120), width=2)
    d.text((80, 205), key, fill="black", font=font(34))
    d.text((60, 300), "Keep this key somewhere safe.", fill=(90, 90, 90), font=font(22))
    f = f"screen-{i:02d}.png"
    img.save(os.path.join(out, f))
    return {"file": f, "question": "What is the activation key shown?", "gold": key}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/images/needs-ocr-10")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(SEED)
    rows = [receipt(rng, i, a.out) for i in range(5)] + [screen(rng, i, a.out) for i in range(5)]
    with open(os.path.join(a.out, "questions.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True) + "\n")
    with open(os.path.join(a.out, "SOURCES.md"), "w") as fh:
        fh.write("# images/needs-ocr-10 — sources\n\nPurpose: AT-237 (M6.T06) text-only fallback (OCR + helper caption).\n\n"
                 "| Files | Made by | Licence |\n|---|---|---|\n| `receipt-00…04.png`, `screen-00…04.png`, `questions.jsonl` | "
                 f"`tools/fixtures/make-screens.py` (Pillow; seed {SEED}; invented shops/apps/codes, built-in font) | CC0 |\n")


if __name__ == "__main__":
    main()
