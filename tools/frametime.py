#!/usr/bin/env python3
"""Extract visual-change timings from a screen recording.

Usage: frametime.py recording.mov [--threshold 0.002] [--crop w:h:x:y] [--json out.json]
Prints each timestamp where the frame changed noticeably, plus the intervals
between changes. Use --crop to isolate one region (e.g. the streaming message)
to measure streaming cadence, animation durations, or transition timing.
--fade-detect (M9.T02, NFR-A4 Reduce Motion): counts frames in which pixels sit strictly between their before and
after values of a change (a fade or cross-fade); 0 = changes are instant. Prints `fade frames: N` (and adds
fade_frames to --json).
--json (M1.T09) also writes {changes, intervals_ms, median_ms, max_ms, first_s, last_s} to a file.
"""
import argparse
import json
import re
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--threshold", type=float, default=0.002)
    ap.add_argument("--crop", help="ffmpeg crop w:h:x:y in source pixels")
    ap.add_argument("--json", help="also write the measurements to this JSON file")
    ap.add_argument("--fade-detect", action="store_true", help="count frames caught mid-fade (0 = no fade)")
    a = ap.parse_args()
    if a.fade_detect:
        n = fade_frames(a.video, a.crop)
        print(f"fade frames: {n}")
        if a.json:
            with open(a.json, "w") as f:
                json.dump({"fade_frames": n, "crop": a.crop}, f, indent=1)
        return

    vf = (f"crop={a.crop}," if a.crop else "") + f"select='gt(scene,{a.threshold})',showinfo"
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", a.video, "-vf", vf, "-f", "null", "-"],
        capture_output=True, text=True,
    )
    times = [float(m) for m in re.findall(r"pts_time:([\d.]+)", proc.stderr)]
    gaps = [round((b - a_) * 1000) for a_, b in zip(times, times[1:])]
    if a.json:
        s = sorted(gaps)
        with open(a.json, "w") as f:
            json.dump({"changes": len(times), "intervals_ms": gaps,
                       "median_ms": s[len(s) // 2] if s else None, "max_ms": s[-1] if s else None,
                       "first_s": times[0] if times else None, "last_s": times[-1] if times else None,
                       "threshold": a.threshold, "crop": a.crop}, f, indent=1)
    if not times:
        print("no changes detected (lower --threshold?)")
        return
    print(f"changes: {len(times)}  first: {times[0]:.3f}s  last: {times[-1]:.3f}s")
    if gaps:
        s = sorted(gaps)
        print(f"interval ms  min {s[0]}  median {s[len(s) // 2]}  max {s[-1]}")
    for t in times:
        print(f"{t:.3f}")


def fade_frames(video, crop, width=160, jump=40, margin=8, stable=3, min_share=0.001):
    """Frames caught mid-transition: per pixel, between two stable runs (≥ `stable` frames, values differing by more
    than `jump`), the frames whose value lies strictly between them (± margin). A frame counts when such pixels are
    ≥ min_share of the frame. An instant change has no frame in between, so it scores 0."""
    vf = (f"crop={crop}," if crop else "") + f"scale={width}:-2,format=gray"
    probe = subprocess.run(["ffmpeg", "-hide_banner", "-i", video, "-vf", vf, "-frames:v", "1", "-f", "image2pipe",
                            "-vcodec", "pgm", "-"], capture_output=True)
    w, h = (int(x) for x in probe.stdout.split(b"\n", 3)[1].split())
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-i", video, "-vf", vf, "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    size = w * h
    frames = [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]
    mid = [0] * len(frames)
    for p in range(size):
        series = [f[p] for f in frames]
        # stable runs: maximal spans whose values stay within ±margin/2 of the run start, length ≥ stable
        runs, i = [], 0
        while i < len(series):
            j = i
            while j + 1 < len(series) and abs(series[j + 1] - series[i]) <= margin // 2:
                j += 1
            if j - i + 1 >= stable:
                runs.append((i, j, series[i]))
            i = j + 1
        for (_, e0, v0), (s1, _, v1) in zip(runs, runs[1:]):
            lo, hi = min(v0, v1), max(v0, v1)
            if hi - lo <= jump:
                continue
            for k in range(e0 + 1, s1):
                if lo + margin < series[k] < hi - margin:
                    mid[k] += 1
    need = max(1, int(size * min_share))
    return sum(1 for m in mid if m >= need)


if __name__ == "__main__":
    main()
