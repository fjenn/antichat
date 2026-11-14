#!/usr/bin/env python3
"""Aggregate bench runs into build/perf/report.json (M0.md C4). Stdlib only.

  report.py ingest --raw RUNS.jsonl [--out build/perf/report.json] [--replace]
  report.py merge  --from OTHER.json [--out ...] [--replace]
  report.py show   [--out ...] [--prefix m0.C2]

Keys: `m0.<metric>.<tier>.<model>` for the XPC path (label `xpc`), `m0.<label>.<metric>.<tier>.<model>`
for other labels (e.g. `inproc`, `vmlx`). Value: {p50, p95, n, unit, nfr, target, scaled_from, label}.
Earlier keys are never overwritten unless --replace is given ("merge appends", M0.md C4). Writes are atomic and
locked (tools/perf/reportio.py, CR-T-12/13); the M1 schema keys (`metrics`, …) are left alone except by `merge`.

Metric mapping from the bench raw rows (App/AntiChat/BenchMode.swift):
  chat ctx=1k → C1 (ttft_s p50 vs NFR-C1), C1b (ttft_s p95 vs NFR-C1b), C2 (decode_tps), R1 (peak bytes,
                GB), XPCMSG (msgs_per_s while streaming, K-NEW-C005-2 ≤ 60)
  chat ctx=4k → C4 (prefill_tps, engine-reported prompt tokens / prefill time), TTFT4K (ttft_s)
  load        → M1 (load_s, labelled [WARM-CACHE] without `sudo purge`)
  restart     → S4 (restart_s: SIGKILL → HelloAck), ORPHAN (orphan_gone_s)
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stats import percentile  # noqa: E402
import reportio  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_OUT = os.path.join(ROOT, "build/perf/report.json")

# nfr.md §2 (C1, C1b, C2, C4), §5 (M1), §6 (R1), §9 (S4); tier column = the tier family.
TARGETS = {
    "C1": {"T0": 1.5, "T1": 1.5, "T2": 1.0, "T3": 0.8, "T4": 0.8},
    "C1b": {"T0": 3.0, "T1": 3.0, "T2": 2.0, "T3": 1.5, "T4": 1.5},
    "C2": {"T0": 20, "T1": 15, "T2": 20, "T3": 30, "T4": 25},
    "C4": {"T0": 150, "T1": 150, "T2": 300, "T3": 400, "T4": 400},
    "R1": {"T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48},
    "S4": 5.0,
    "ORPHAN": 5.0,
    "XPCMSG": 60,
}
UNITS = {"C1": "s", "C1b": "s", "C2": "tok/s", "C4": "tok/s", "R1": "GB", "M1": "s", "S4": "s", "ORPHAN": "s",
         "XPCMSG": "msg/s", "TTFT4K": "s"}
HIGHER_IS_BETTER = {"C2", "C4"}


def m1_target(weights_gb: float) -> float:
    # NFR-M1: ≤ 3 s for ≤ 6 GB weights; ≤ 8 s ≤ 22 GB; ≤ 12 s ≤ 40 GB; ≤ 25 s ≤ 75 GB.
    for lim, t in ((6, 3), (22, 8), (40, 12), (75, 25)):
        if weights_gb <= lim:
            return t
    return float("nan")


def target_for(metric: str, tier: str, row: dict):
    fam = tier.split("-")[0]
    t = TARGETS.get(metric)
    if metric == "M1":
        w = row.get("weights_gb")
        return m1_target(w) if w else None
    if isinstance(t, dict):
        return t.get(tier, t.get(fam))
    return t


def load(path):
    return reportio.load(path)


def put(data, key, val, replace):
    if reportio.put_legacy(data, key, val, replace):
        print(f"[ok] {key} p50={val['p50']:.4g} p95={val['p95']:.4g} n={val['n']} {val['unit']} target={val['target']} pass={val.get('pass')}")


def entry(metric, tier, xs, label, extra=None):
    xs = [x for x in xs if x is not None and x > 0]
    if not xs:
        return None
    p50, p95 = percentile(xs, 50), percentile(xs, 95)
    tgt = target_for(metric, tier, extra or {})
    v = {"p50": p50, "p95": p95, "n": len(xs), "unit": UNITS.get(metric, ""), "nfr": f"NFR-{metric}" if metric in TARGETS or metric == "M1" else None,
         "target": tgt, "scaled_from": None, "label": label, "min": min(xs), "max": max(xs)}
    if tgt is not None:
        if metric == "C1b":
            v["pass"] = p95 <= tgt
        elif metric in HIGHER_IS_BETTER:
            v["pass"] = p50 >= tgt
        elif metric == "R1":
            v["pass"] = v["max"] <= tgt
        else:
            v["pass"] = p50 <= tgt
    if extra:
        v.update({k: extra[k] for k in ("weights_gb",) if k in extra})
    return v


def ingest(args):
    rows = [json.loads(l) for l in open(args.raw) if l.strip()]
    rows = [r for r in rows if "error" not in r]
    if not rows:
        print(f"[fail] {args.raw}: no successful runs")
        return 1
    r0 = rows[0]
    model, tier, label, cmd = r0["model"], r0["tier"], r0.get("label", "xpc"), r0["cmd"]
    if model.startswith("gguf:"):
        model = os.path.basename(model[5:])
    with reportio.locked(args.out) as data:
        return _ingest(args, data, rows, model, tier, label, cmd)


def _ingest(args, data, rows, model, tier, label, cmd):
    prefix = "m0" if label == "xpc" else f"m0.{label}"
    status = {"measured": "measured"}
    lbl = "measured"

    def k(metric):
        return f"{prefix}.{metric}.{tier}.{model}"

    if cmd == "chat" and rows[0].get("ctx", "1k") == "1k":
        put(data, k("C1"), entry("C1", tier, [r["ttft_s"] for r in rows], lbl), args.replace)
        put(data, k("C1b"), entry("C1b", tier, [r["ttft_s"] for r in rows], lbl), args.replace)
        put(data, k("C2"), entry("C2", tier, [r["decode_tps"] for r in rows if r.get("decode_tps", -1) > 0], lbl), args.replace)
        put(data, k("R1"), entry("R1", tier, [r["peak_footprint_bytes"] / 1e9 for r in rows], lbl), args.replace)
        put(data, k("XPCMSG"), entry("XPCMSG", tier, [r["msgs_per_s"] for r in rows if r.get("msgs_per_s", -1) > 0], lbl), args.replace)
    elif cmd == "chat":
        put(data, k("C4"), entry("C4", tier, [r["prefill_tps"] for r in rows if r.get("prefill_tps", -1) > 0], lbl), args.replace)
        put(data, k("TTFT4K"), entry("TTFT4K", tier, [r["ttft_s"] for r in rows], lbl), args.replace)
        put(data, k("R1-4k"), entry("R1", tier, [r["peak_footprint_bytes"] / 1e9 for r in rows], lbl), args.replace)
    elif cmd == "load":
        w = args.weights_gb
        put(data, k("M1"), entry("M1", tier, [r["load_s"] for r in rows], "[WARM-CACHE]", {"weights_gb": w}), args.replace)
    elif cmd == "restart":
        put(data, k("S4"), entry("S4", tier, [r["restart_s"] for r in rows], lbl), args.replace)
        put(data, k("ORPHAN"), entry("ORPHAN", tier, [r["orphan_gone_s"] for r in rows], lbl), args.replace)
    else:
        print(f"[skip] cmd {cmd} not aggregated")
    _ = status
    return 0


def merge(args):
    if not os.path.exists(args.src):
        print(f"[fail] {args.src}: no such report")
        return 1
    src = load(args.src)
    with reportio.locked(args.out) as data:
        for key, val in reportio.legacy_items(src):
            put(data, key, val, args.replace)
        for metric, tiers in (src.get("metrics") or {}).items():
            for tier, e in tiers.items():
                if reportio.put_metric(data, metric, tier, e, args.replace):
                    print(f"[ok] metrics.{metric}.{tier}")
    return 0


def show(args):
    for key, v in sorted(reportio.legacy_items(load(args.out))):
        if args.prefix and not key.startswith(args.prefix):
            continue
        print(f"{key:55s} p50={v['p50']:.4g} p95={v['p95']:.4g} n={v['n']} {v['unit']} target={v['target']} pass={v.get('pass')} {v['label']}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("ingest")
    a.add_argument("--raw", required=True)
    a.add_argument("--out", default=DEFAULT_OUT)
    a.add_argument("--replace", action="store_true")
    a.add_argument("--weights-gb", type=float, default=None)
    m = sub.add_parser("merge")
    m.add_argument("--from", dest="src", required=True)
    m.add_argument("--out", default=DEFAULT_OUT)
    m.add_argument("--replace", action="store_true")
    s = sub.add_parser("show")
    s.add_argument("--out", default=DEFAULT_OUT)
    s.add_argument("--prefix", default="")
    args = ap.parse_args()
    return {"ingest": ingest, "merge": merge, "show": show}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
