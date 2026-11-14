#!/usr/bin/env python3
"""fixtures/prompts/sheet-to-chart-20.jsonl (M6.T12, AT-274 check 3): 20 "make a chart" prompts over budget-20k.xlsx
(Transactions, Monthly, Categories), each with `aggregates_gold` = the [label, value] pairs the chart must plot, computed here from the files
(stdlib + openpyxl, independent of DuckDB; the same group-by arithmetic pandas would do — pandas is not in the tools env).
Row: {"id", "files", "prompt", "mark", "aggregates_gold": [[label, value], ...]}. Labels are strings (months
"YYYY-MM"); values are ints where the source is integer, else floats (compared ≤ 1e-9 relative). Deterministic.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-sheet-chart.py --out fixtures
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from collections import defaultdict


def main() -> None:
    import openpyxl

    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures")
    args = ap.parse_args()
    office = os.path.join(args.out, "docs", "office")
    wb = openpyxl.load_workbook(os.path.join(office, "budget-20k.xlsx"), read_only=True, data_only=True)
    tx = [dict(zip(["txn_id", "date", "category", "region", "amount", "qty", "reimbursed"], r))
          for r in list(wb["Transactions"].iter_rows(values_only=True))[1:]]
    monthly = [dict(zip(["month", "planned", "actual"], r)) for r in list(wb["Monthly"].iter_rows(values_only=True))[1:]]
    for t in tx:
        if isinstance(t["date"], dt.datetime):
            t["date"] = t["date"].date()

    items: list[dict] = []

    def add(files, prompt, mark, pairs):
        items.append({"id": f"sc-{len(items) + 1:02d}", "files": files, "prompt": prompt, "mark": mark,
                      "aggregates_gold": [[str(k), v] for k, v in pairs]})

    def group(rows, key, val, op="sum", where=lambda r: True):
        acc, n = defaultdict(list), defaultdict(int)
        is_int = True
        for r in rows:
            if not where(r):
                continue
            k = key(r)
            v = 1 if op == "count" else r[val]
            is_int = is_int and isinstance(v, int) and not isinstance(v, bool)
            acc[k].append(v)
            n[k] += 1
        out = []
        for k in sorted(acc):
            total = sum(acc[k]) if is_int else math.fsum(acc[k])  # exact float sum
            out.append((k, total / n[k] if op == "avg" else total))
        return out

    B = ["budget-20k.xlsx"]
    cat, reg = (lambda r: r["category"]), (lambda r: r["region"])
    ym = lambda r: r["date"].strftime("%Y-%m")
    add(B, "Make a bar chart of the total transaction amount per category.", "bar", group(tx, cat, "amount"))
    add(B, "Chart the total transaction amount per region as a bar chart.", "bar", group(tx, reg, "amount"))
    add(B, "Make a bar chart of how many transactions each category has.", "bar", group(tx, cat, None, "count"))
    add(B, "Chart the number of transactions per region.", "bar", group(tx, reg, None, "count"))
    add(B, "Make a bar chart of the average transaction amount per region.", "bar", group(tx, reg, "amount", "avg"))
    add(B, "Make a bar chart of the total quantity (qty) per category.", "bar", group(tx, cat, "qty"))
    for g in ["North", "South", "East", "West"]:
        add(B, f"Make a bar chart of the total amount per category for the {g} region only.", "bar",
            group(tx, cat, "amount", where=lambda r, g=g: r["region"] == g))
    add(B, "Make a line chart of the total transaction amount per month (YYYY-MM) in 2025.", "line",
        group(tx, ym, "amount", where=lambda r: r["date"].year == 2025))
    add(B, "Make a line chart of the total transaction amount per month (YYYY-MM) in 2026.", "line",
        group(tx, ym, "amount", where=lambda r: r["date"].year == 2026))
    add(B, "Make a bar chart of the total amount of reimbursed transactions per category.", "bar",
        group(tx, cat, "amount", where=lambda r: r["reimbursed"] is True))
    mon = lambda r: r["month"].strftime("%Y-%m")
    add(B, "Using the Monthly sheet, make a line chart of the actual spend per month (YYYY-MM).", "line", group(monthly, mon, "actual"))
    add(B, "Using the Monthly sheet, make a line chart of the planned spend per month (YYYY-MM).", "line", group(monthly, mon, "planned"))
    cats = [dict(zip(["category", "budget", "owner"], r)) for r in list(wb["Categories"].iter_rows(values_only=True))[1:]]
    add(B, "Using the Categories sheet, make a bar chart of the budget per category.", "bar", group(cats, cat, "budget"))
    add(B, "Using the Monthly sheet, make a bar chart of actual minus planned per month (YYYY-MM).", "bar",
        [(mon(r), r["actual"] - r["planned"]) for r in sorted(monthly, key=mon)])
    add(B, "Make a bar chart of the average transaction amount per category.", "bar", group(tx, cat, "amount", "avg"))
    add(B, "Make a bar chart of the total amount per category for transactions with qty above 25.", "bar",
        group(tx, cat, "amount", where=lambda r: r["qty"] > 25))
    add(B, "Make a bar chart of the largest single transaction amount per region.", "bar",
        [(k, max(t["amount"] for t in tx if t["region"] == k)) for k in sorted({t["region"] for t in tx})])
    assert len(items) == 20, len(items)
    path = os.path.join(args.out, "prompts", "sheet-to-chart-20.jsonl")
    with open(path, "w") as f:
        for it in items:
            f.write(json.dumps(it, sort_keys=True) + "\n")
    print(f"wrote {path} ({len(items)} prompts)")


if __name__ == "__main__":
    main()
