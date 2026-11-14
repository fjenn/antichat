#!/usr/bin/env python3
"""First output sound in a recorded waveform (M0.T05 step 3, blackhole mode): the start of the first
10 ms window above the threshold (default −50 dBFS) at or after `--after` seconds. With last-voiced.py on
the input channel this gives end-of-speech → first output sample from one recording.

Usage: python3 -I tools/audio/first-sound.py FILE.wav [--channel 1] [--after 0] [--dbfs -50]
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavtools import read_wav, window_dbfs  # noqa: E402


def first_sound(path: str, channel: int = 0, after: float = 0.0, dbfs: float = -50.0) -> float | None:
    x, rate = read_wav(path, channel)
    w = window_dbfs(x, rate)
    for i in range(int(after / 0.010), len(w)):
        if w[i] > dbfs:
            return i * 0.010
    return None


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--channel", type=int, default=0)
    ap.add_argument("--after", type=float, default=0.0)
    ap.add_argument("--dbfs", type=float, default=-50.0)
    a = ap.parse_args()
    t = first_sound(a.file, a.channel, a.after, a.dbfs)
    print("none" if t is None else f"{t:.3f}")
    sys.exit(0 if t is not None else 1)
