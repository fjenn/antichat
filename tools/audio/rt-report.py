#!/usr/bin/env python3
"""Voice round-trip report (M0.T05 step 4–5; AT-M0-05). Stdlib only; run with `python3 -I`.

Reads the raw voice runs written by `tools/bench.sh voice` (build/perf/raw/voice-*.jsonl, one JSON object
per turn; `kind: warm` rows only carry the warm-up footprint) and writes:
  - build/perf/report.json keys (merge; --replace overwrites):
      m0.V1.<tier>.<model>              NFR-V1  p50 (and p95 = NFR-V1b), s, with the mode label
      m0.V1b.<tier>.<model>             NFR-V1b p95 view of the same runs
      m0.V2.<stage>.<tier>.<model>      per-stage p50 (ms) vs NFR-V2's best-tier split (info on T0/T1)
      m0.R1.voice.<tier>.<model>        NFR-R1 peak phys_footprint (app + helper), GB, max vs B
    A `-system` TTS run is keyed `…<model>+system`.
  - <at-dir>/stages.csv                 one row per run file: n, V1 p50/p95, stage p50s, peak RSS, verdicts
  - <at-dir>/rt-summary.json            the same, machine-readable (used by tools/m0/at-m0-05.sh)
Usage: python3 -I tools/audio/rt-report.py [--raw FILE ...] [--out build/perf/report.json]
                                          [--at-dir build/at/AT-M0-05] [--replace]
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf"))
from stats import percentile  # noqa: E402

V1 = {"T0": 2.5, "T1": 1.5, "T2": 1.2, "T3": 1.0, "T4": 1.0}
V1B = {"T0": 3.5, "T1": 2.5, "T2": 2.0, "T3": 1.8, "T4": 1.8}
B = {"T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48}
STAGES = ["endpointing", "stt_final", "llm_ttft", "first_clause", "tts_first_chunk", "audio_out"]
V2 = {"endpointing": 450, "stt_final": 100, "llm_ttft": 200, "first_clause": 120, "tts_first_chunk": 100, "audio_out": 30}


def fam(tier: str) -> str:
    return tier.split("-")[0]


def summarize(path: str) -> dict | None:
    rows = [json.loads(l) for l in open(path) if l.strip()]
    warm = [r for r in rows if r.get("kind") == "warm"]
    turns = [r for r in rows if r.get("kind") == "turn"]
    if not turns:
        return None
    ok = [r for r in turns if "error" not in r and r.get("v1_s", -1) > 0]
    r0 = turns[0]
    tier, model, label = r0["tier"], r0["model"], r0.get("mode_label", r0.get("mode"))
    tts = sorted({r.get("tts_used", "?") for r in ok})
    v1 = [r["v1_s"] for r in ok]
    v1w = [r["v1_waveform_s"] for r in ok if r.get("v1_waveform_s", -1) > 0]
    st = {s: percentile([r[f"stage_{s}_ms"] for r in ok if f"stage_{s}_ms" in r], 50) for s in STAGES}
    peaks = [r.get("peak_footprint_bytes", 0) for r in turns + warm]
    peak_gb = max(peaks) / 1e9 if peaks else 0
    mtl = max([r.get("mtl_allocated_bytes", 0) for r in ok] or [0]) / 1e9
    b = B.get(tier)
    reasons = {}
    for r in ok:
        reasons[r.get("turn_end_reason", "?")] = reasons.get(r.get("turn_end_reason", "?"), 0) + 1
    s = {
        "file": path, "tier": tier, "model": model, "mode": label, "tts_requested": r0.get("tts_requested"),
        "tts_used": tts, "n": len(ok), "n_attempted": len(turns), "errors": [r.get("error") for r in turns if "error" in r][:5],
        "v1_p50": percentile(v1, 50), "v1_p95": percentile(v1, 95), "v1_min": min(v1) if v1 else None, "v1_max": max(v1) if v1 else None,
        "v1_waveform_p50": percentile(v1w, 50) if v1w else None,
        "v1_target": V1.get(fam(tier)), "v1b_target": V1B.get(fam(tier)),
        "stages_p50_ms": st, "peak_rss_gb": round(peak_gb, 3), "mtl_allocated_gb": round(mtl, 3), "budget_b_gb": b,
        "kokoro_errors": sum(1 for r in ok if r.get("kokoro_error")), "turn_end_reasons": reasons,
        "os": r0.get("os"),
    }
    s["v1_pass"] = s["v1_p50"] <= s["v1_target"] if s["v1_target"] else None
    s["v1b_pass"] = s["v1_p95"] <= s["v1b_target"] if s["v1b_target"] else None
    s["fits_b"] = (peak_gb <= b) if b else None
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", nargs="*")
    ap.add_argument("--out", default="build/perf/report.json")
    ap.add_argument("--at-dir", default="build/at/AT-M0-05")
    ap.add_argument("--replace", action="store_true")
    a = ap.parse_args()
    files = a.raw or sorted(glob.glob("build/perf/raw/voice-*.jsonl"))
    files = [f for f in files if "-live-" not in f]
    sums = [s for s in (summarize(f) for f in files) if s]
    if not sums:
        print("[fail] no voice runs")
        return 1
    data = json.load(open(a.out)) if os.path.exists(a.out) else {}

    def put(key, val):
        if key in data and not a.replace:
            print(f"[skip] {key} exists (use --replace)")
            return
        data[key] = val
        print(f"[ok] {key}")

    for s in sums:
        mk = s["model"] + ("+system" if s["tts_requested"] == "system" else "")
        common = {"n": s["n"], "label": s["mode"], "scaled_from": None, "tts": s["tts_used"], "min": s["v1_min"], "max": s["v1_max"]}
        put(f"m0.V1.{s['tier']}.{mk}", {**common, "p50": s["v1_p50"], "p95": s["v1_p95"], "unit": "s", "nfr": "NFR-V1",
                                         "target": s["v1_target"], "pass": s["v1_pass"]})
        put(f"m0.V1b.{s['tier']}.{mk}", {**common, "p50": s["v1_p50"], "p95": s["v1_p95"], "unit": "s", "nfr": "NFR-V1b",
                                          "target": s["v1b_target"], "pass": s["v1b_pass"]})
        for st, v in s["stages_p50_ms"].items():
            best = fam(s["tier"]) in ("T3", "T4")
            put(f"m0.V2.{st}.{s['tier']}.{mk}", {"p50": v, "p95": None, "n": s["n"], "unit": "ms", "nfr": "NFR-V2",
                                                 "target": V2[st] if best else None, "pass": (v <= V2[st]) if best else None,
                                                 "label": s["mode"], "scaled_from": None})
        put(f"m0.R1.voice.{s['tier']}.{mk}", {"p50": s["peak_rss_gb"], "p95": s["peak_rss_gb"], "max": s["peak_rss_gb"], "n": s["n"] + 1,
                                              "unit": "GB", "nfr": "NFR-R1", "target": s["budget_b_gb"], "pass": s["fits_b"],
                                              "label": f"{s['mode']} resident voice set (chat+stt+vad+turn+{','.join(s['tts_used'])})",
                                              "mtl_allocated_gb": s["mtl_allocated_gb"], "scaled_from": None})
    with open(a.out, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.makedirs(a.at_dir, exist_ok=True)
    with open(os.path.join(a.at_dir, "stages.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["tier", "model", "tts_requested", "tts_used", "mode", "n", "v1_p50_s", "v1_p95_s", "v1_target_s", "v1_pass",
                    "v1b_target_s", "v1b_pass"] + [f"{s}_p50_ms" for s in STAGES] + ["peak_rss_gb", "budget_b_gb", "fits_b", "kokoro_errors"])
        for s in sums:
            w.writerow([s["tier"], s["model"], s["tts_requested"], "+".join(s["tts_used"]), s["mode"], s["n"], f"{s['v1_p50']:.3f}",
                        f"{s['v1_p95']:.3f}", s["v1_target"], s["v1_pass"], s["v1b_target"], s["v1b_pass"]]
                       + [f"{s['stages_p50_ms'][x]:.1f}" for x in STAGES] + [s["peak_rss_gb"], s["budget_b_gb"], s["fits_b"], s["kokoro_errors"]])
    with open(os.path.join(a.at_dir, "rt-summary.json"), "w") as f:
        json.dump(sums, f, indent=1)
    for s in sums:
        st = " ".join(f"{k}={v:.0f}" for k, v in s["stages_p50_ms"].items())
        print(f"{s['tier']:6s} {s['model']:12s} tts={'+'.join(s['tts_used']):7s} {s['mode']} n={s['n']} V1 p50={s['v1_p50']:.3f}s "
              f"p95={s['v1_p95']:.3f}s (target {s['v1_target']}/{s['v1b_target']}: {s['v1_pass']}/{s['v1b_pass']}) | {st} | "
              f"peak {s['peak_rss_gb']:.2f} GB vs B {s['budget_b_gb']} fit={s['fits_b']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
