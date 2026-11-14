#!/usr/bin/env python3
"""AT-271 fixtures (M6.T04): "scanned" pages with known text, degraded like a real office scan.
  fixtures/docs/ocr-30p/page-NN.pdf + page-NN.gt.txt   30 single-page image-only PDFs (letter, 300 dpi) of invented
                                                       Latin-script prose; ground truth = the exact rendered lines
  fixtures/docs/tables-20/table-NN.pdf + tables-20.gt.json  20 pages, each one ruled table (3-6 cols x 4-10 rows incl. the
                                                       header) under a heading; gt = {file: {rows, cols}}
  fixtures/docs/pdf/scan-60p-contract.pdf              60-page image-only "contract" (150 dpi, lighter degradation:
                                                       size), the tile-progress / send-before-finish fixture
Degradation (packet §0.5): rotation uniform in ±1.5°, Gaussian noise sigma 6, JPEG quality 70, grayscale.
Seed 20261107; text from a fixed invented word list; font: Pillow's built-in scalable font (no system fonts), CC0.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-scans.py --out fixtures
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SEED = 20261107
WORDS = ("harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel canal "
         "ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar willow river "
         "market winter garden letter station bridge window morning evening village mountain").split()
HEADERS = ["Item", "Region", "Quarter", "Amount", "Owner", "Status", "Code", "Units", "Price", "Total"]


def font(px: int):
    return ImageFont.load_default(size=px)


def sentence(rng: random.Random) -> str:
    n = rng.randint(6, 12)
    ws = [rng.choice(WORDS) for _ in range(n)]
    if rng.random() < 0.4:
        ws.insert(rng.randint(1, n - 1), str(rng.randint(2, 990)))
    s = " ".join(ws)
    return s[0].upper() + s[1:] + "."


def wrap(text: str, f, width: int, d: ImageDraw.ImageDraw) -> list[str]:
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) > width and cur:
            lines.append(cur)
            cur = w
        else:
            cur = t
    if cur:
        lines.append(cur)
    return lines


def degrade(img: Image.Image, rng: random.Random, nprng: np.random.Generator, sigma: float, quality: int) -> Image.Image:
    angle = rng.uniform(-1.5, 1.5)
    img = img.rotate(angle, resample=Image.BICUBIC, expand=False, fillcolor=255)
    a = np.asarray(img, dtype=np.float32) + nprng.normal(0.0, sigma, (img.height, img.width))
    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), mode="L")
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return Image.open(io.BytesIO(buf.getvalue()))


def text_page(rng: random.Random, dpi: int, title: str) -> tuple[Image.Image, list[str]]:
    w, h = int(8.5 * dpi), int(11 * dpi)
    img = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(img)
    margin = dpi
    body = font(int(dpi * 0.15))      # ≈ 11 pt
    head = font(int(dpi * 0.22))
    y = margin
    lines = [title]
    d.text((margin, y), title, fill=0, font=head)
    y += int(dpi * 0.45)
    while True:
        para = " ".join(sentence(rng) for _ in range(rng.randint(2, 4)))
        pl = wrap(para, body, w - 2 * margin, d)
        if y + len(pl) * int(dpi * 0.24) > h - margin:
            break
        for ln in pl:
            d.text((margin, y), ln, fill=0, font=body)
            y += int(dpi * 0.24)
            lines.append(ln)
        y += int(dpi * 0.14)
    return img, lines


def table_page(rng: random.Random, dpi: int, title: str) -> tuple[Image.Image, int, int]:
    w, h = int(8.5 * dpi), int(11 * dpi)
    img = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(img)
    margin = dpi
    cols, rows = rng.randint(3, 6), rng.randint(4, 10)
    d.text((margin, margin), title, fill=0, font=font(int(dpi * 0.22)))
    d.text((margin, margin + int(dpi * 0.4)), sentence(rng), fill=0, font=font(int(dpi * 0.15)))
    top = margin + int(dpi * 0.9)
    cw, rh = (w - 2 * margin) // cols, int(dpi * 0.36)
    hdr = rng.sample(HEADERS, cols)
    f = font(int(dpi * 0.14))
    for r in range(rows):
        for c in range(cols):
            x0, y0 = margin + c * cw, top + r * rh
            d.rectangle([x0, y0, x0 + cw, y0 + rh], outline=0, width=max(2, dpi // 100))
            if r == 0:
                t = hdr[c]
            elif c == 0:
                t = rng.choice(WORDS).title()
            else:
                t = str(rng.randint(1, 9999))
            d.text((x0 + int(dpi * 0.08), y0 + int(dpi * 0.09)), t, fill=0, font=f)
    return img, rows, cols


def save_pdf(pages: list[Image.Image], path: str, dpi: int):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pages[0].save(path, "PDF", resolution=float(dpi), save_all=True, append_images=pages[1:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures")
    a = ap.parse_args()
    rng = random.Random(SEED)
    nprng = np.random.default_rng(SEED)

    ocr = os.path.join(a.out, "docs/ocr-30p")
    os.makedirs(ocr, exist_ok=True)
    for i in range(1, 31):
        img, lines = text_page(rng, 300, f"{rng.choice(WORDS).title()} {rng.choice(WORDS).title()} Notes {i}")
        save_pdf([degrade(img, rng, nprng, 6.0, 70)], os.path.join(ocr, f"page-{i:02d}.pdf"), 300)
        with open(os.path.join(ocr, f"page-{i:02d}.gt.txt"), "w") as fh:
            fh.write("\n".join(lines) + "\n")

    tables = os.path.join(a.out, "docs/tables-20")
    gt = {}
    for i in range(1, 21):
        img, rows, cols = table_page(rng, 300, f"Table {i}: {rng.choice(WORDS).title()} Summary")
        name = f"table-{i:02d}.pdf"
        save_pdf([degrade(img, rng, nprng, 6.0, 70)], os.path.join(tables, name), 300)
        gt[name] = {"rows": rows, "cols": cols}
    with open(os.path.join(a.out, "docs/tables-20.gt.json"), "w") as fh:
        json.dump(gt, fh, indent=1, sort_keys=True)
        fh.write("\n")

    pages = []
    for i in range(1, 61):
        img, _ = text_page(rng, 150, f"Service Agreement - Clause {i}")
        pages.append(degrade(img, rng, nprng, 4.0, 60))
    save_pdf(pages, os.path.join(a.out, "docs/pdf/scan-60p-contract.pdf"), 150)

    for folder, rows in [(ocr, "`page-NN.pdf` + `page-NN.gt.txt` (30 pages)"), (tables, "`table-NN.pdf` (20) + `../tables-20.gt.json`")]:
        with open(os.path.join(folder, "SOURCES.md"), "w") as fh:
            fh.write(f"# {os.path.relpath(folder, a.out)} — sources\n\nPurpose: AT-271 (M6.T04) OCR CER / table shape.\n\n"
                     f"| Files | Made by | Licence |\n|---|---|---|\n| {rows} | `tools/fixtures/make-scans.py` (Pillow, numpy; "
                     f"seed {SEED}; invented text, Pillow built-in font; ±1.5° rotation, noise σ 6, JPEG q70, 300 dpi) | CC0 |\n")


if __name__ == "__main__":
    main()
