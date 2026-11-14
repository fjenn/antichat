#!/usr/bin/env python3
"""Aggregate the M0.T07 video bench rows and scale NFR-VID1/VID2 to reference chips (M0.T07 step 6; K-015). Stdlib.

Video time ≈ C ÷ pp512 (nfr.md NFR-VID1 note; hardware-tiers §4.3), so a time measured on the dev Mac (M5 Max,
S4) is scaled to a chip by × pp512(M5 Max) ÷ pp512(chip) — the same rule as tools/perf/sd-scale.py. The whole
request → MP4 time is scaled, although text encoding, weight load and the MP4 mux do not scale with pp512
[ASSUMPTION: conservative, they are < 20 % of the total on S4]. Every scaled value is labelled `[SCALED]`: a
hypothesis for hardware we do not have (D-003, Q-004). Runs use a warm page cache (3 consecutive jobs) and are
labelled `[WARM-CACHE]` in the report.

Targets (nfr.md §4): VID1 S1 480p ~3 s ≤ 480 s · S2 720p ≤ 480 s · S3 720p ≤ 210 s · S4 720p ≤ 90 s;
VID2 S1 30 s · S2 20 · S3 10 · S4 5. A row at a class's non-default resolution is reported with
`default_res: false` and no pass/fail.

Keys (tools/perf/report.py format): m0.VID1.S4.vid-5b-<res>, m0.VID2.S4.vid-5b-<res> (+ `@<chip>` scaled),
m0.VID1.S4.vid-i2v-<res> (sd.cpp I2V, measured only), m0.R1.T3-48.video-<res>.

  vid-scale.py --raw-dir build/perf/raw [--report build/perf/report.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reportio  # noqa: E402  (atomic + locked writes, --replace semantics: CR-T-12/13)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scale import CHIPS  # noqa: E402

SRC = "M5 Max"
CLASS = {"M1": "S1", "M4": "S1", "M4 Pro": "S2", "M5": "S3", "M4 Max": "S3"}
VID1 = {"S1": 480, "S2": 480, "S3": 210, "S4": 90}
VID2 = {"S1": 30, "S2": 20, "S3": 10, "S4": 5}
DEFAULT_RES = {"S1": "480p", "S2": "720p", "S3": "720p", "S4": "720p"}


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def rows(raw_dir, name):
    p = os.path.join(raw_dir, name + ".jsonl")
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


def entry(xs, nfr, target, label, unit="s", extra=None, use_max=False):
    xs = [x for x in xs if x is not None and x >= 0]
    if not xs:
        return None
    v = {"p50": pct(xs, 50), "p95": pct(xs, 95), "n": len(xs), "unit": unit, "nfr": nfr, "target": target,
         "scaled_from": None, "label": label, "min": min(xs), "max": max(xs)}
    if target is not None:
        # R1 (peak memory) is judged on the worst run, as in report.py / sd-scale.py; times on p50.
        v["pass"] = (v["max"] if use_max else v["p50"]) <= target
    v.update(extra or {})
    return v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default="build/perf/raw")
    ap.add_argument("--report", default="build/perf/report.json")
    ap.add_argument("--replace", action="store_true", help="overwrite existing keys (default: append only, CR-T-12)")
    a = ap.parse_args()
    with reportio.locked(a.report) as rep:
        return _run(a, rep)


def _run(a, rep) -> int:
    src_pp = CHIPS[SRC][1]

    def put(k, v):
        if v is None:
            print(f"[skip] {k}: no values")
            return
        if not reportio.put_legacy(rep, k, v, a.replace):
            return
        tgt = "" if v.get("target") is None else f" target {v['target']} {'PASS' if v.get('pass') else 'FAIL'}"
        print(f"{k}: p50 {v['p50']:.2f} p95 {v['p95']:.2f} n={v['n']} {v['label']}{tgt}")

    for res in ("480p", "720p"):
        rr = [r for r in rows(a.raw_dir, f"video-t2v-{res}") if r.get("run", -1) >= 0 and r.get("status") == "completed"]
        if not rr:
            continue
        frames = rr[0].get("frames")
        extra = {"res": res, "frames": frames, "cache": "[WARM-CACHE]", "default_res": DEFAULT_RES["S4"] == res}
        for metric, key, tbl in (("VID1", "final_s", VID1), ("VID2", "first_preview_s", VID2)):
            base_k = f"m0.{metric}.S4.vid-5b-{res}"
            xs = [r.get(key) for r in rr]
            put(base_k, entry(xs, f"NFR-{metric}", tbl["S4"] if res == DEFAULT_RES["S4"] else None, "measured", extra=extra))
            for chip, cls in CLASS.items():
                f = src_pp / CHIPS[chip][1]
                d = dict(extra, default_res=DEFAULT_RES[cls] == res, speed_class=cls, factor=round(f, 3))
                v = entry([x * f for x in xs if x is not None and x >= 0], f"NFR-{metric}",
                          tbl[cls] if DEFAULT_RES[cls] == res else None, "[SCALED]", extra=d)
                if v:
                    v["scaled_from"] = "M5 Max S4"
                put(f"{base_k}@{chip}", v)
        put(f"m0.R1.T3-48.video-{res}", entry([r.get("peak_footprint_bytes", 0) / 1e9 for r in rr], "NFR-R1", 36,
                                               "measured", unit="GB", extra={"res": res}, use_max=True))
    for res in ("480p", "720p"):
        ri = [r for r in rows(a.raw_dir, f"video-i2v-{res}") if r.get("run", -1) >= 0 and r.get("status") == "completed"]
        put(f"m0.VID1.S4.vid-i2v-{res}", entry([r.get("final_s") for r in ri], "NFR-VID1", None, "measured",
                                              extra={"res": res, "engine": "sd-cli e239e4b", "frames": ri[0].get("frames") if ri else None,
                                                     "steps": ri[0].get("h_total_steps") if ri else None}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
