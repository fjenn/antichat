#!/usr/bin/env python3
"""Contrast sampler for text over onboarding art (M2.T18; AT-201 part 1, H3; tokens.md `onb.scrim.step1`).
Run with `python3 -I` (stdlib only).

  contrast-sampler.py <background.png> [--points 64] [--min 4.5] [--region x0,y0,x1,y1] [--fg FFFFFF[:alpha]]

Samples an evenly spaced grid of `--points` pixels (8 × 8 for 64) inside `--region` (fractions of the image; default
the step-1 text block 0.18,0.25,0.55,0.75) of a render of the *background only* (art + scrim, no text), composites
the foreground colour (alpha over each sample) and prints the WCAG 2.x contrast of each. Exit 1 if any point is below
`--min`. PNG decoding is a minimal 8-bit RGB/RGBA non-interlaced reader (what NSBitmapImageRep writes).
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib


def read_png(path: str) -> tuple[int, int, int, bytes]:
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, f"unsupported PNG (depth {depth}, type {ctype})"
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bpp, bytes(out)


def lum(rgb: tuple[float, float, float]) -> float:
    def ch(v: float) -> float:
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v / 255) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--points", type=int, default=64)
    ap.add_argument("--min", type=float, default=4.5)
    ap.add_argument("--region", default="0.18,0.25,0.55,0.75")
    ap.add_argument("--fg", default="FFFFFF")
    a = ap.parse_args()
    w, h, bpp, px = read_png(a.image)
    x0, y0, x1, y1 = (float(v) for v in a.region.split(","))
    hexpart, _, alpha = a.fg.partition(":")
    fg = tuple(int(hexpart[i:i + 2], 16) for i in (0, 2, 4))
    fa = float(alpha) if alpha else 1.0
    side = int(math.isqrt(a.points))
    results = []
    for j in range(side):
        for i in range(side):
            x = int((x0 + (x1 - x0) * (i + 0.5) / side) * w)
            y = int((y0 + (y1 - y0) * (j + 0.5) / side) * h)
            o = (y * w + x) * bpp
            bg = tuple(px[o:o + 3])
            top = tuple(fa * f + (1 - fa) * b for f, b in zip(fg, bg))
            l1, l2 = lum(top), lum(bg)
            results.append(round((max(l1, l2) + 0.05) / (min(l1, l2) + 0.05), 2))
    worst = min(results)
    ok = sum(r >= a.min for r in results)
    print(json.dumps({"image": a.image, "fg": a.fg, "points": len(results), "pass": ok, "min": worst,
                      "median": sorted(results)[len(results) // 2], "threshold": a.min}))
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
