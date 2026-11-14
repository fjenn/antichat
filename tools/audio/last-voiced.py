#!/usr/bin/env python3
"""End of speech in a recorded/input waveform (M0.T05 step 3, blackhole mode): the end of the last 10 ms
window above the threshold (default −50 dBFS). Prints seconds from the file start.
The helper's `[IN-PIPELINE]` mode applies the same rule in Swift (`lastVoicedSample`, Endpointing.swift).

Usage: python3 -I tools/audio/last-voiced.py FILE.wav [--channel 0] [--dbfs -50]
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavtools import read_wav, window_dbfs  # noqa: E402


def last_voiced(path: str, channel: int = 0, dbfs: float = -50.0) -> float | None:
    x, rate = read_wav(path, channel)
    w = window_dbfs(x, rate)
    for i in range(len(w) - 1, -1, -1):
        if w[i] > dbfs:
            return (i + 1) * 0.010
    return None


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--channel", type=int, default=0)
    ap.add_argument("--dbfs", type=float, default=-50.0)
    a = ap.parse_args()
    t = last_voiced(a.file, a.channel, a.dbfs)
    print("none" if t is None else f"{t:.3f}")
    sys.exit(0 if t is not None else 1)
