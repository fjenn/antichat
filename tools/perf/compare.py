#!/usr/bin/env python3
"""Regression check of build/perf/report.json against a baseline (M1.T26 step 2; PRD §4; test-strategy §6/§10).

  compare.py [--report build/perf/report.json] (--baseline FILE | --baseline-ref <git ref>) [--json out.json]

For every `metrics.<ID>.<tier>` present in both reports, the metric's gate statistic (nfr_targets.json `gate_stat`,
e.g. p50 for C1, p99 for U2) is compared in the metric's direction:
  regression > 5 %                → S2 bug
  regression > 25 % on a ★ metric → S1 bug (★ = U1, U2, C1, C2, V1, P1, M5)
Entries marked noisy (`valid: false`, machine load, tools/perf/load.py) on either side are never compared: they are
listed as "not comparable" so a busy shared Mac cannot fake or hide a regression. A baseline written before the M1
schema (flat `m0.<metric>.<tier>.<model>` keys, M0 report) is mapped onto `metrics.<metric>.<tier>` when the model
matches.

Exit: 0 no S1/S2 regression · 1 at least one · 2 usage error (no baseline / unreadable).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reportio  # noqa: E402

ROOT = reportio.ROOT
S2_PCT, S1_PCT = 5.0, 25.0


def load_baseline(a) -> dict:
    if a.baseline:
        return reportio.load(a.baseline)
    p = subprocess.run(["git", "-C", ROOT, "show", f"{a.baseline_ref}:build/perf/report.json"], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"[fail] git show {a.baseline_ref}:build/perf/report.json: {p.stderr.strip()}")
    return json.loads(p.stdout)


def entries(rep: dict, targets: dict) -> dict[tuple[str, str, str | None], dict]:
    """(metric, tier, model) → entry. Legacy flat keys `m0|m1.<metric>.<tier>.<model>` (no label, no @chip) are
    mapped when they name a known metric; the model stays part of the key so a baseline is only ever compared with
    a measurement of the same model."""
    out = {}
    for m, tiers in (rep.get("metrics") or {}).items():
        for t, e in tiers.items():
            out[(m, t, e.get("model"))] = e
    for k, v in reportio.legacy_items(rep):
        parts = k.split(".")
        if len(parts) < 4 or parts[0] not in ("m0", "m1") or "@" in k:
            continue
        metric, tier, model = parts[1], parts[2], ".".join(parts[3:])
        if metric not in targets:
            continue
        out.setdefault((metric, tier, model), dict(v, model=model, quality="clean", valid=True, legacy_key=k))
    return out


def compare(cur: dict, base: dict, targets: dict) -> list[dict]:
    rows = []
    ce, be = entries(cur, targets), entries(base, targets)
    for key in sorted(set(ce) & set(be), key=lambda k: tuple("" if x is None else str(x) for x in k)):  # model may be None
        metric, tier, model = key
        c, b = ce[key], be[key]
        t = targets.get(metric, {})
        stat = t.get("gate_stat", "p50")
        direction = t.get("direction", "lower")
        row = {"metric": metric, "tier": tier, "model": model, "stat": stat, "current": c.get(stat), "baseline": b.get(stat),
               "unit": c.get("unit"), "star": bool(t.get("star")), "severity": None, "change_pct": None}
        if not c.get("valid", True) or not b.get("valid", True):
            row["status"] = "not comparable (noisy run)"
        elif row["current"] is None or not row["baseline"]:
            row["status"] = "not comparable (no value)"
        elif direction not in ("lower", "higher"):
            row["status"] = f"not compared ({direction} target)"
        else:
            cv, bv = float(row["current"]), float(row["baseline"])
            worse = (cv - bv) / bv * 100 if direction == "lower" else (bv - cv) / bv * 100
            row["change_pct"] = round(worse, 2)
            if worse > S1_PCT and row["star"]:
                row["severity"] = "S1"
            elif worse > S2_PCT:
                row["severity"] = "S2"
            row["status"] = "regression" if row["severity"] else ("improved" if worse < 0 else "ok")
        rows.append(row)
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=reportio.DEFAULT_REPORT)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--baseline")
    g.add_argument("--baseline-ref")
    ap.add_argument("--json")
    ap.add_argument("--targets", default=os.path.join(HERE, "nfr_targets.json"))
    a = ap.parse_args(argv)
    if not os.path.exists(a.report):
        print(f"[fail] {a.report}: no report", file=sys.stderr)
        return 2
    targets = json.load(open(a.targets))["metrics"]
    rows = compare(reportio.load(a.report), load_baseline(a), targets)
    for r in rows:
        c = r["change_pct"]
        ch = "" if c is None else " ±0%" if abs(c) < 0.05 else f" {c:+.1f}% worse" if c > 0 else f" {-c:.1f}% better"
        sev = f" [{r['severity']}]" if r["severity"] else ""
        mdl = f" [{r['model']}]" if r["model"] else ""
        print(f"{r['metric']:>13}.{r['tier']:<12}{mdl} {r['stat']} {r['baseline']} → {r['current']} {r['unit'] or ''}{ch}{sev}  {r['status']}")
    bad = [r for r in rows if r["severity"]]
    summary = {"compared": sum(1 for r in rows if r["change_pct"] is not None), "not_comparable": sum(1 for r in rows if r["change_pct"] is None),
               "S1": sum(1 for r in bad if r["severity"] == "S1"), "S2": sum(1 for r in bad if r["severity"] == "S2")}
    print(f"[{'fail' if bad else 'ok'}] {summary}")
    if a.json:
        reportio.save(a.json, {"summary": summary, "rows": rows})
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
