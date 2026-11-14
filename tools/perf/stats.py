#!/usr/bin/env python3
"""Percentiles for perf reports (nfr.md "Statistics"; M0.md C4). Stdlib only.

p50/p95 use linear interpolation between closest ranks (numpy's default "linear" method), so results
match `numpy.percentile(x, q)`.

Usage as a tool: python3 -I tools/perf/stats.py 1.2 1.4 1.1 ...  → prints n, p50, p95, min, max.
"""
from __future__ import annotations

import math
import sys


def percentile(xs: list[float], q: float) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * q / 100.0
    lo = math.floor(pos)
    hi = math.ceil(pos)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def summary(xs: list[float]) -> dict:
    return {"n": len(xs), "p50": percentile(xs, 50), "p95": percentile(xs, 95),
            "min": min(xs) if xs else None, "max": max(xs) if xs else None}


if __name__ == "__main__":
    vals = [float(a) for a in sys.argv[1:]]
    print(summary(vals))
