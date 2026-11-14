#!/usr/bin/env python3
"""Aggregate the M0.T06 image bench rows and scale P1/P2 to reference chips (M0.T06 step 4; K-015). Stdlib only.

Image time ≈ C ÷ pp512 (hardware-tiers §4.3), so a time measured on the dev Mac (M5 Max, S4) is scaled to a
chip by × pp512(M5 Max) ÷ pp512(chip). Every scaled value is labelled `[SCALED]`: a hypothesis for hardware we
do not have (D-003, Q-004). Chips per speed class (hardware-tiers §2.3): S1 M1 + M4, S2 M4 Pro, S3 M5 + M4 Max.
NFR-P1 targets per class (nfr.md §4): P1 S1 150 s · S2 60 · S3 45 · S4 20.
NFR-P2 (first visible preview) is not judged here (M9.T05): under A-M4-R1/A-M4-R1b every bench preview (~128 px) is
withheld and the card shows its progress state instead, measured on screen by the XCUITest leg
ImageFirstVisiblePerfTests (build/at/AT-NFR-P2/perf-uitest.json). The bench's request → first denoise step is kept as
a diagnostic without a target (`m0.P2step1.*`: text encode + one full step).
The class default resolution is 768² on S1/S2 and 1024² on S3/S4; rows at the other resolution are scaled
too (the gate asks for both) and carry `default_res: false`.

Writes report keys (tools/perf/report.py format):
  m0.P1.S4.img-klein-<q>-<res>  m0.P2step1.S4.… (diagnostic)  (+ `@<chip>` scaled copies)
  m0.M3-unload.T1.chat-9b-q4  m0.M3-reload.T1.chat-9b-q4  m0.R1.T1.handoff  m0.R1.T2-24.coresident
  m0.C1.T2-24.chat-9b-q4-after-image  m0.cancel-stop.S4.img-klein-q4-1024
and a per-run CSV of the handoff/coresident runs (--csv).

  sd-scale.py --raw-dir build/perf/raw [--report build/perf/report.json] [--csv build/at/AT-M0-06/handoff.csv]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scale import CHIPS  # noqa: E402  (same chip table as the chat scaling)
import reportio  # noqa: E402  (atomic + locked writes, --replace semantics: CR-T-12/13)

SRC = "M5 Max"
CLASS = {"M1": "S1", "M4": "S1", "M4 Pro": "S2", "M5": "S3", "M4 Max": "S3"}
P1T = {"S1": 150, "S2": 60, "S3": 45, "S4": 20}
P2T = {"S1": 5, "S2": 3, "S3": 2, "S4": 1}
DEFAULT_RES = {"S1": 768, "S2": 768, "S3": 1024, "S4": 1024}


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def entry(xs, unit, nfr, target, label, higher=False, use_max=False, extra=None):
    xs = [x for x in xs if x is not None and x >= 0]
    if not xs:
        return None
    v = {"p50": pct(xs, 50), "p95": pct(xs, 95), "n": len(xs), "unit": unit, "nfr": nfr, "target": target,
         "scaled_from": None, "label": label, "min": min(xs), "max": max(xs)}
    if target is not None:
        val = v["max"] if use_max else v["p50"]
        v["pass"] = val >= target if higher else val <= target
    v.update(extra or {})
    return v


def rows(raw_dir, name):
    p = os.path.join(raw_dir, name + ".jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p) if l.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default="build/perf/raw")
    ap.add_argument("--report", default="build/perf/report.json")
    ap.add_argument("--replace", action="store_true", help="overwrite existing keys (default: append only, CR-T-12)")
    ap.add_argument("--csv", default=None)
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
        print(f"[ok] {k} p50={v['p50']:.4g} p95={v['p95']:.4g} n={v['n']} {v['unit']} target={v['target']} pass={v.get('pass')} {v['label']}")

    for q, res in (("q4", 768), ("q4", 1024), ("q8", 1024), ("q8", 768)):
        rr = [r for r in rows(a.raw_dir, f"image-{q}-{res}") if r.get("run", -1) >= 0 and r.get("status") == "completed"]
        if not rr:
            continue
        model = f"img-klein-{q}-{res}"
        if a.replace:  # M9.T05: the old P2 keys held the step-1 time judged against the P2 bar; superseded by m0.P2step1
            for old in [f"m0.P2.S4.{model}"] + [f"m0.P2.S4.{model}@{chip}" for chip in CLASS]:
                if rep.pop(old, None) is not None:
                    print(f"[retired] {old} (NFR-P2 = on-screen progress state, A-M4-R1b; step-1 time → m0.P2step1)")
        for metric, field, tgt in (("P1", "final_s", P1T), ("P2step1", "first_step_s", None)):
            xs = [r.get(field, r.get("first_preview_s")) for r in rr]
            k = f"m0.{metric}.S4.{model}"
            nfr = "NFR-P1" if metric == "P1" else None
            ex = {} if tgt else {"definition": "request → first denoise step event (diagnostic; NFR-P2 is the on-screen "
                                               "progress state under A-M4-R1b, ImageFirstVisiblePerfTests)"}
            put(k, entry(xs, "s", nfr, tgt["S4"] if tgt else None, "measured",
                         extra={"res": res, "default_res": res == DEFAULT_RES["S4"], **ex}))
            for chip, cls in CLASS.items():
                f = src_pp / CHIPS[chip][1]
                put(f"{k}@{chip}", entry([x * f for x in xs], "s", nfr, tgt[cls] if tgt else None, "[SCALED]",
                                         extra={"scaled_from": f"{SRC} S4", "class": cls, "factor": round(f, 2), "res": res,
                                                "default_res": res == DEFAULT_RES[cls]}))
        put(f"m0.R1.S4.{model}", entry([r["peak_footprint_bytes"] / 1e9 for r in rr], "GB", "NFR-R1", None, "measured", use_max=True))

    h = [r for r in rows(a.raw_dir, "handoff-T1") if r.get("run", -1) >= 0]
    if h:
        put("m0.M3-unload.T1.chat-9b-q4", entry([r.get("unload_s") for r in h if r.get("evicted")], "s", "NFR-M3", 1.0, "measured"))
        put("m0.M3-reload.T1.chat-9b-q4", entry([r.get("queued_chat_first_token_s") for r in h], "s", "NFR-M1", 3.0, "[WARM-CACHE]",
                                                extra={"definition": "image result received → first token of a chat request sent at that instant (queued behind sd-server stop + reload)"}))
        put("m0.R1.T1.handoff", entry([r.get("peak_footprint_bytes", 0) / 1e9 for r in h], "GB", "NFR-R1", 9.5, "measured", use_max=True))
        put("m0.P1.T1.handoff-request-to-final", entry([r.get("final_s") for r in h], "s", "NFR-P1", None, "measured",
                                                       extra={"definition": "includes evict + cold sd-server start + lazy weight load"}))
    c = [r for r in rows(a.raw_dir, "coresident-T2-24") if r.get("run", -1) >= 0]
    if c:
        put("m0.R1.T2-24.coresident", entry([r.get("peak_footprint_bytes", 0) / 1e9 for r in c], "GB", "NFR-R1", 16.0, "measured", use_max=True))
        put("m0.C1.T2-24.chat-9b-q4-after-image", entry([r.get("next_chat_ttft_s") for r in c], "s", "NFR-C1", 1.5, "measured"))
    x = [r for r in rows(a.raw_dir, "cancel-q4-1024") if r.get("run", -1) >= 0]
    if x:
        # M9.T05: both from the cancel request (NFR-VID3 "cancel frees GPU memory ≤ 2 s"; the server is aborted at once).
        # A run without a value (-1) fails the key instead of dropping out of it.
        def vals(k):
            return [r.get(k, -1) if r.get(k, -1) is not None and r.get(k, -1) >= 0 else 999.0 for r in x]
        put("m0.cancel-stop.S4.img-klein-q4-1024", entry(vals("h_cancel_to_stopped_s"), "s", "NFR-VID3", 2.0, "measured", use_max=True))
        put("m0.cancel-memrecover.S4.img-klein-q4-1024", entry(vals("h_cancel_mem_recover_s"), "s", "NFR-VID3", 2.0, "measured", use_max=True))

    if a.csv:
        cols = ["bench", "run", "tier", "quant", "res", "evicted", "unload_s", "unload_call_s", "h_image_load_s", "final_s",
                "first_preview_s", "preview_count", "image_unload_s", "chat_reload_call_s", "queued_chat_first_token_s",
                "queued_chat_answered", "queued_chat_load_states", "container_before", "container_after", "container_unchanged",
                "next_chat_ttft_s", "next_chat_reloaded", "peak_footprint_bytes", "sha256"]
        with open(a.csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            for name, rr in (("handoff-T1", h), ("coresident-T2-24", c)):
                for r in rr:
                    w.writerow([name] + [r.get(k, "") for k in cols[1:]])
        print(f"[ok] {a.csv}: {len(h) + len(c)} rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
