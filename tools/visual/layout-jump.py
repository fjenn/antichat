#!/usr/bin/env python3
"""Layout jumps of already-rendered text in a screen recording (M1.T09; NFR-U5 "0 layout jumps > 4 px", H2).

Usage: layout-jump.py <recording.mov | frames-dir> [--crop w:h:x:y] [--step-ms 50] [--json out.json]

How: ffmpeg decodes each frame of the (cropped) region to a 1-pixel-wide grey column (area average of every pixel
row), i.e. a vertical ink profile. For two frames ≥ step apart it finds
  1. the global vertical shift that best aligns them (the transcript scrolling as the reply grows is not a jump),
  2. then, band by band (48 px) over the rows that already had text in the earlier frame, the band's own best shift.
A band whose best shift differs from the global one by d px (and fits clearly better than the global shift) moved
relative to the rest: a layout jump of d px. The newest two text bands of the earlier frame are excluded (that is
where words are still arriving and fading in). Prints the worst jump and writes
{pairs, max_jump_px, jumps_over_4px, worst: [...]} with --json. Stdlib only (`python3 -I`).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

BAND = 48
LOCAL = 12


def frames(src: str, crop: str | None) -> tuple[list[float], list[bytes], int]:
    vf = (f"crop={crop}," if crop else "") + "scale=1:ih:flags=area,format=gray,showinfo"
    if os.path.isdir(src):
        names = sorted(n for n in os.listdir(src) if n.lower().endswith(".png"))
        args = ["-framerate", "30", "-pattern_type", "glob", "-i", os.path.join(src, "*.png")]
        if not names:
            sys.exit(f"no PNG frames in {src}")
    else:
        args = ["-i", src]
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "info", *args, "-vf", vf, "-fps_mode", "passthrough",
                        "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True)
    if p.returncode != 0:
        sys.exit(p.stderr.decode(errors="replace")[-2000:])
    err = p.stderr.decode(errors="replace")
    times = [float(x.split("pts_time:")[1].split()[0]) for x in err.splitlines() if "pts_time:" in x]
    h = None
    for line in err.splitlines():
        if "Stream" in line and "Video:" in line and "gray" in line and "1x" in line:
            h = int(line.split("1x")[1].split(",")[0].split()[0].split("[")[0])
    if h is None:
        h = len(p.stdout) // max(1, len(times))
    cols = [p.stdout[i * h:(i + 1) * h] for i in range(len(p.stdout) // h)]
    return times[:len(cols)], cols, h


def background(col: bytes) -> int:
    hist = [0] * 256
    for v in col:
        hist[v] += 1
    return max(range(256), key=hist.__getitem__)


def diff(a: bytes, b: bytes, a0: int, a1: int, s: int) -> float:
    """Mean |a[y] - b[y+s]| over a's rows [a0, a1) that land inside b."""
    lo = max(a0, -s)
    hi = min(a1, len(b) - s)
    if hi - lo < 8:
        return float("inf")
    tot = 0
    for y in range(lo, hi):
        d = a[y] - b[y + s]
        tot += d if d >= 0 else -d
    return tot / (hi - lo)


def ink_rows(col: bytes, bg: int, tol: int = 3) -> list[bool]:
    return [abs(v - bg) > tol for v in col]


def compare(a: bytes, b: bytes, max_shift: int) -> tuple[int, int, int]:
    """(global shift, worst residual jump px, band start of the worst) for frames a → b."""
    bg = background(a)
    ink = ink_rows(a, bg)
    bands = [y for y in range(0, len(a) - BAND + 1, BAND) if sum(ink[y:y + BAND]) >= 4]
    if len(bands) <= 2:
        return 0, 0, -1
    stable = bands[:-2]  # the newest two text bands may still be growing / fading
    top, bottom = stable[0], stable[-1] + BAND
    best_s, best_d = 0, diff(a, b, top, bottom, 0)
    if best_d > 0:
        for s in range(-max_shift, max_shift + 1):
            d = diff(a, b, top, bottom, s)
            if d < best_d:
                best_s, best_d = s, d
    worst, where = 0, -1
    for y in stable:
        dg = diff(a, b, y, y + BAND, best_s)
        if dg < 1.0:
            continue  # the band sits where the global shift puts it
        bl, bd = best_s, dg
        for s in range(best_s - LOCAL, best_s + LOCAL + 1):
            d = diff(a, b, y, y + BAND, s)
            if d < bd:
                bl, bd = s, d
        if bl != best_s and bd < 0.5 * dg:
            j = abs(bl - best_s)
            if j > worst:
                worst, where = j, y
    return best_s, worst, where


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--crop", help="ffmpeg crop w:h:x:y in source pixels")
    ap.add_argument("--step-ms", type=float, default=50, help="compare frames at least this far apart")
    ap.add_argument("--max-shift", type=int, default=96, help="largest scroll between compared frames, px")
    ap.add_argument("--threshold", type=int, default=4, help="a jump is > this many px")
    ap.add_argument("--json")
    a = ap.parse_args()
    times, cols, h = frames(a.src, a.crop)
    pairs = []
    i = 0
    while i < len(cols) - 1:
        j = i + 1
        while j < len(cols) - 1 and (times[j] - times[i]) * 1000 < a.step_ms:
            j += 1
        if cols[i] != cols[j]:
            g, jump, where = compare(cols[i], cols[j], a.max_shift)
            pairs.append({"t0": times[i], "t1": times[j], "scroll_px": g, "jump_px": jump, "band_y": where})
        i = j
    over = [p for p in pairs if p["jump_px"] > a.threshold]
    worst = sorted(pairs, key=lambda p: -p["jump_px"])[:10]
    out = {"frames": len(cols), "height_px": h, "pairs": len(pairs), "max_jump_px": max((p["jump_px"] for p in pairs), default=0),
           "jumps_over_threshold": len(over), "threshold_px": a.threshold, "step_ms": a.step_ms, "crop": a.crop,
           "worst": worst}
    print(f"frames {len(cols)}  pairs {len(pairs)}  max jump {out['max_jump_px']} px  "
          f"jumps > {a.threshold} px: {len(over)}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
