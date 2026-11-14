#!/usr/bin/env python3
"""Scale M0 measurements from the dev Mac to reference chips (M0.md C5; test-strategy §6). Stdlib only.

decode (C2) × memory-bandwidth ratio; prefill (C4) × pp512 ratio; TTFT (C1, C1b, TTFT4K) ÷ pp512 ratio
(TTFT is prefill-bound for a ≤ 1K prompt [ASSUMPTION]). Load (M1), memory (R1) and XPC metrics are not
scaled. Every scaled value is labelled `[SCALED]` with `scaled_from`; they are hypotheses for hardware we
do not have (D-003, Q-004).

Chip table: hardware-tiers.md §1.1 (bandwidth GB/s; llama.cpp 7B Q4_0 pp512, range midpoints).

  scale.py [--report build/perf/report.json] [--from "M5 Max"] [--prefix m0.]
Writes keys `<key>@<chip>` for the reference chips of the key's tier (REFS below). Existing scaled keys are kept
unless --replace (CR-T-12); the write is atomic and locked (CR-T-13).
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reportio  # noqa: E402  (atomic + locked writes, --replace semantics: CR-T-12/13)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CHIPS = {  # name: (bandwidth GB/s, pp512 tok/s)
    "M1": (68, 113), "M1 Pro": (200, 250), "M1 Max": (400, 465),
    "M2": (100, 163), "M2 Pro": (200, 318), "M2 Max": (400, 605),
    "M3": (100, 187), "M3 Pro": (150, 306), "M3 Max": (400, 664),
    "M4": (120, 221), "M4 Pro": (273, 402), "M4 Max": (546, 800),
    "M5": (153.6, 723), "M5 Pro": (307, 1480), "M5 Max": (614, 3220),
    "M6": (170, 989),
}
# Reference chips per tier (model-matrix §2.1 speed columns; hardware-tiers §2.2/§2.3).
REFS = {"T0": ["M1", "M2"], "T1": ["M4", "M5", "M3 Pro"], "T2": ["M4", "M4 Pro"], "T3": ["M4 Pro", "M3 Max"], "T4": ["M4 Max", "M2 Max"]}
DECODE = {"C2"}
PREFILL = {"C4"}
TTFT = {"C1", "C1b", "TTFT4K"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=os.path.join(ROOT, "build/perf/report.json"))
    ap.add_argument("--from", dest="src", default="M5 Max")
    ap.add_argument("--prefix", default="m0.")
    ap.add_argument("--replace", action="store_true", help="overwrite existing <key>@<chip> entries")
    a = ap.parse_args()
    with reportio.locked(a.report) as data:
        _scale(a, data)


def _scale(a, data):
    sbw, spp = CHIPS[a.src]
    added = 0
    for key, v in list(reportio.legacy_items(data)):
        if "@" in key or not key.startswith(a.prefix) or v.get("label") == "[SCALED]":
            continue
        # m0[.<label>].<metric>.<tier>.<model>; the model key may contain dots (chat-0.8b).
        parts = key.split(".")
        idx = next((i for i, p in enumerate(parts[1:3], 1) if p in DECODE | PREFILL | TTFT), None)
        if idx is None:
            continue
        metric, tier = parts[idx], parts[idx + 1]
        fam = tier.split("-")[0]
        for chip in REFS.get(fam, []):
            bw, pp = CHIPS[chip]
            f = bw / sbw if metric in DECODE else (pp / spp if metric in PREFILL else spp / pp)
            nv = dict(v)
            nv.update({"p50": v["p50"] * f, "p95": v["p95"] * f, "min": (v.get("min") or 0) * f, "max": (v.get("max") or 0) * f,
                       "scaled_from": f"{a.src} S4", "label": "[SCALED]", "factor": f, "chip": chip})
            tgt = v.get("target")
            if tgt is not None:
                if metric == "C1b":
                    nv["pass"] = nv["p95"] <= tgt
                elif metric in DECODE | PREFILL:
                    nv["pass"] = nv["p50"] >= tgt
                else:
                    nv["pass"] = nv["p50"] <= tgt
            if not reportio.put_legacy(data, f"{key}@{chip}", nv, a.replace):
                continue
            added += 1
            print(f"[SCALED] {key}@{chip} p50={nv['p50']:.4g} ×{f:.3f} target={tgt} pass={nv.get('pass')}")
    print(f"[ok] {added} scaled keys")


if __name__ == "__main__":
    main()
