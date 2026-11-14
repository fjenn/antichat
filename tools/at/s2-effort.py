#!/usr/bin/env python3
"""S-2 effort ratio (M1.T01 step 4.1, AT-M1-S2 pass condition (d)).

Reads docs/research/07-spikes/S-2-effort.csv (header: date,task,hours,remaining_estimate[,source]) — one row per
working session on M1.T02…M1.T11, 8 agent wall-clock hours = 1 working day — and prints
  actual_days   = sum(hours) / 8 + max(remaining_estimate on the last row of each task, in days)
                  (incomplete scope counts against the budget by extrapolation, never silently extended)
  ratio         = actual_days / 10           (10 = the planned S-2 share of G-001…G-006, M1.T01 step 2)
  projected_pw  = ratio × 13                 (G-001…G-006 = 13 pw, registry/gaps.json)
  pass          = ratio ≤ 2.0                (D-012 switch rule, second half)
The optional `source` column marks how a row's hours were obtained (`logged` = written by the session,
`reconstructed` = derived afterwards from commit timestamps, see S-2-shell-parity.md). Both count.

Usage: python3 -I tools/at/s2-effort.py docs/research/07-spikes/S-2-effort.csv [--json out.json]
stdlib only. Exit 0 when ratio ≤ 2.0, 1 otherwise, 2 on a malformed file.
"""
import argparse
import csv
import json
import sys

HOURS_PER_DAY = 8.0
PLANNED_DAYS = 10.0
GAPS_PW = 13.0
MAX_RATIO = 2.0
SCOPE = {f"M1.T{n:02d}" for n in range(2, 12)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("csv")
    ap.add_argument("--json")
    a = ap.parse_args()
    rows = []
    with open(a.csv, newline="") as f:
        for i, r in enumerate(csv.DictReader(f), start=2):
            try:
                hours = float(r["hours"])
                rem = float(r["remaining_estimate"]) if (r.get("remaining_estimate") or "").strip() else 0.0
            except (KeyError, ValueError) as e:
                print(f"s2-effort: line {i}: {e}", file=sys.stderr)
                return 2
            rows.append({"date": r["date"], "task": r["task"], "hours": hours, "remaining_days": rem,
                         "source": (r.get("source") or "logged").strip() or "logged"})
    out_of_scope = sorted({r["task"] for r in rows if r["task"] not in SCOPE})
    scoped = [r for r in rows if r["task"] in SCOPE]
    hours = sum(r["hours"] for r in scoped)
    per_task: dict[str, dict] = {}
    for r in scoped:
        t = per_task.setdefault(r["task"], {"hours": 0.0, "sessions": 0, "remaining_days": 0.0, "sources": set()})
        t["hours"] += r["hours"]
        t["sessions"] += 1
        t["remaining_days"] = r["remaining_days"]  # the task's last row holds its current estimate
        t["sources"].add(r["source"])
    remaining = sum(t["remaining_days"] for t in per_task.values())
    actual_days = hours / HOURS_PER_DAY + remaining
    ratio = actual_days / PLANNED_DAYS
    result = {
        "hours": round(hours, 2), "logged_days": round(hours / HOURS_PER_DAY, 3), "remaining_days": round(remaining, 3),
        "actual_days": round(actual_days, 3), "ratio": round(ratio, 3), "projected_pw": round(ratio * GAPS_PW, 2),
        "planned_days": PLANNED_DAYS, "max_ratio": MAX_RATIO, "pass": ratio <= MAX_RATIO,
        "band": "fail (> 2.0: D-012 F1, major, ask)" if ratio > MAX_RATIO
        else "pass with overrun (1.5–2.0: re-plan, minor)" if ratio >= 1.5 else "pass",
        "missing_tasks": sorted(SCOPE - set(per_task)), "out_of_scope_rows": out_of_scope,
        "tasks": {k: {**v, "hours": round(v["hours"], 2), "sources": sorted(v["sources"])} for k, v in sorted(per_task.items())},
    }
    if a.json:
        with open(a.json, "w") as f:
            json.dump(result, f, indent=1)
            f.write("\n")
    print(f"actual_days {result['actual_days']} (hours {result['hours']} + remaining {result['remaining_days']} d) · "
          f"ratio {result['ratio']} · projected_pw {result['projected_pw']} · {result['band']}")
    if result["missing_tasks"]:
        print("missing tasks (no row): " + ", ".join(result["missing_tasks"]))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
