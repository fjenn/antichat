#!/usr/bin/env python3
"""NFR-C7 stats from `-Bench swap` raw runs (M0.T09 step 2). stdlib only; `python3 -I`.
Prints JSON {direction: {p50, p95, n, errors, load_p50, peak_footprint_gb_max}} and, with --report, merges
`m0.C7.<tier>.<direction>` into build/perf/report.json (keeps other keys)."""
from __future__ import annotations

import argparse
import json
import os
import statistics


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    if not xs:
        return -1
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--tier", default="T1")
    ap.add_argument("--target", type=float, default=9.5, help="NFR-M1 band (8 s for 6-22 GB) + NFR-C1 T1 (1.5 s)")
    ap.add_argument("--report")
    o = ap.parse_args()
    runs = [json.loads(l) for l in open(o.raw) if l.strip()]
    out = {}
    for d in sorted({r["direction"] for r in runs}):
        rs = [r for r in runs if r["direction"] == d]
        ok = [r for r in rs if "error" not in r and r.get("swap_s", -1) > 0]
        xs = [r["swap_s"] for r in ok]
        out[d] = {"p50": round(statistics.median(xs), 3) if xs else -1, "p95": round(pct(xs, 0.95), 3), "n": len(xs),
                  "errors": len(rs) - len(ok), "load_p50": round(statistics.median([r["load_s"] for r in ok]), 3) if ok else -1,
                  "peak_footprint_gb_max": round(max(r.get("peak_footprint_bytes", 0) for r in rs) / 1e9, 2),
                  "target_s": o.target, "pass": bool(xs) and pct(xs, 0.95) <= o.target}
    print(json.dumps(out, indent=2))
    if o.report:
        rep = json.load(open(o.report)) if os.path.exists(o.report) else {}
        for d, v in out.items():
            rep[f"m0.C7.{o.tier}.{d.replace('->', '_to_')}"] = {
                "p50": v["p50"], "p95": v["p95"], "n": v["n"], "unit": "s", "nfr": "NFR-C7", "target": o.target,
                "scaled_from": None, "label": "measured [WARM-CACHE]", "model": "chat-9b-q4 <-> evil-9b"}
        with open(o.report, "w") as f:
            json.dump(rep, f, indent=2, sort_keys=True)
            f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
