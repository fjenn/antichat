#!/usr/bin/env python3
"""DMG window background (M10.T02 step 1; R-225 AC1; D-014 line). Deterministic; no hand edits.

Input: the owner's art docs/research/02-target/inputs/onboarding-reference/onboarding-dreamworld-background.png
(Git LFS; a pointer file is smudged through `git lfs smudge`). Output, committed next to this script:
  background.png (660×420), background@2x.png (1320×840) and background.tiff (both representations, via
  `tiffutil -cathidpicheck`; Finder picks the 2× one on Retina).
Look: the art cover-cropped and desaturated, a light veil so the icon labels stay legible, an arrow from the app
(180,200) to the Applications link (480,200), and the line "Drag to Applications · Requires macOS 26 Tahoe or
later · Apple silicon" on a solid band (contrast ≥ 4.5:1, checked here and printed).
Run with the release venv (Pillow): build/release-venv/bin/python -I tools/release/dmg/make-background.py
"""
from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFont

ROOT = Path(__file__).resolve().parents[3]
ART = ROOT / "docs/research/02-target/inputs/onboarding-reference/onboarding-dreamworld-background.png"
OUT = Path(__file__).resolve().parent
W, H = 660, 420
LINE = "Drag to Applications · Requires macOS 26 Tahoe or later · Apple silicon"
APP, LINK = (180, 200), (480, 200)
INK = (28, 28, 34)
BAND = (250, 250, 252)
FONT = "/System/Library/Fonts/SFNS.ttf"


def load_art() -> Image.Image:
    data = ART.read_bytes()
    if data.startswith(b"version https://git-lfs"):
        data = subprocess.run(["git", "-C", str(ROOT), "lfs", "smudge"], input=data, capture_output=True,
                              check=True).stdout
    return Image.open(io.BytesIO(data)).convert("RGB")


def luminance(c: tuple[int, int, int]) -> float:
    def ch(v: int) -> float:
        s = v / 255
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def render(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    art = load_art()
    k = max(w / art.width, h / art.height)  # cover crop, centred
    art = art.resize((round(art.width * k), round(art.height * k)), Image.LANCZOS)
    left, top = (art.width - w) // 2, (art.height - h) // 2
    img = art.crop((left, top, left + w, top + h))
    img = ImageEnhance.Color(img).enhance(0.35)            # desaturate
    img = Image.blend(img, Image.new("RGB", img.size, (255, 255, 255)), 0.55)  # light veil for icon labels
    d = ImageDraw.Draw(img)
    # Arrow between the two icons (128 px icons → leave 80 px clear around each centre).
    y = APP[1] * scale
    x0, x1 = (APP[0] + 88) * scale, (LINK[0] - 88) * scale
    d.line([(x0, y), (x1 - 14 * scale, y)], fill=INK, width=4 * scale)
    d.polygon([(x1, y), (x1 - 18 * scale, y - 11 * scale), (x1 - 18 * scale, y + 11 * scale)], fill=INK)
    # Requirements band.
    band_top = (H - 54) * scale
    d.rectangle([(0, band_top), (w, h)], fill=BAND)
    font = ImageFont.truetype(FONT, 13 * scale)
    tw = d.textlength(LINE, font=font)
    d.text(((w - tw) / 2, band_top + 19 * scale), LINE, font=font, fill=INK)
    return img


def main() -> int:
    ratio = contrast(INK, BAND)
    if ratio < 4.5:
        print(f"make-background: contrast {ratio:.2f} < 4.5", file=sys.stderr)
        return 1
    one, two = OUT / "background.png", OUT / "background@2x.png"
    render(1).save(one, optimize=True)
    img2 = render(2)
    img2.info["dpi"] = (144, 144)
    img2.save(two, optimize=True, dpi=(144, 144))
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT / "background.tiff")],
                   check=True, capture_output=True)
    print(f"make-background: {one.name} {W}x{H}, {two.name} {2 * W}x{2 * H}, background.tiff; "
          f"line contrast {ratio:.1f}:1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
