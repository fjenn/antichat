#!/usr/bin/env python3
"""fixtures/docs/office/sheet-qa-50.jsonl (M6.T08, AT-272 check 3a): 50 sum / avg / group / filter / top-n questions
over budget-20k.xlsx (Transactions, Monthly, Categories) and notes.csv, gold answers computed here from the files
(stdlib + openpyxl: the same arithmetic pandas would do; values rounded to 2 decimals, the question says so).
Row: {"id", "files": [...], "question", "kind": "number"|"text", "answer"}. Deterministic (no randomness).

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-sheet-qa.py --out fixtures
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
from collections import defaultdict


def r2(x: float) -> float:
    return float(f"{x + 0.0:.2f}")


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
    cats = [dict(zip(["category", "budget", "owner"], r)) for r in list(wb["Categories"].iter_rows(values_only=True))[1:]]
    with open(os.path.join(office, "notes.csv"), newline="") as f:
        notes = list(csv.DictReader(f))
    for n in notes:
        n["amount"] = float(n["amount"])
    for t in tx:
        if isinstance(t["date"], dt.datetime):
            t["date"] = t["date"].date()

    B, N = ["budget-20k.xlsx"], ["notes.csv"]
    items: list[dict] = []

    def add(files, q, kind, ans):
        items.append({"id": f"sq-{len(items) + 1:02d}", "files": files, "question": q, "kind": kind, "answer": ans})

    by_cat = defaultdict(float)
    by_cat_n = defaultdict(int)
    by_reg = defaultdict(float)
    by_reg_n = defaultdict(int)
    for t in tx:
        by_cat[t["category"]] += t["amount"]; by_cat_n[t["category"]] += 1
        by_reg[t["region"]] += t["amount"]; by_reg_n[t["region"]] += 1
    for c in ["Rent", "Food", "Travel", "Software", "Marketing"]:  # 5 sums
        add(B, f"What is the total amount spent on {c} across all transactions? Round to 2 decimal places.", "number", r2(by_cat[c]))
    for g in ["North", "South", "East", "West"]:  # 4 averages
        add(B, f"What is the average transaction amount in the {g} region? Round to 2 decimal places.", "number",
            r2(by_reg[g] / by_reg_n[g]))
    add(B, "How many transactions are marked as reimbursed?", "number", float(sum(1 for t in tx if t["reimbursed"])))
    for g in ["East", "West"]:
        add(B, f"How many transactions are there in the {g} region?", "number", float(by_reg_n[g]))
    for (y, m) in [(2025, 3), (2025, 11), (2026, 6)]:  # 3 monthly qty sums
        q = sum(t["qty"] for t in tx if t["date"].year == y and t["date"].month == m)
        add(B, f"What is the total quantity (qty) of all transactions dated in {dt.date(y, m, 1):%B %Y}?", "number", float(q))
    add(B, "Which category has the highest total transaction amount? Answer with the category name.", "text",
        max(by_cat, key=by_cat.get))
    add(B, "Which region has the most transactions? Answer with the region name.", "text", max(by_reg_n, key=by_reg_n.get))
    avg_cat = {c: by_cat[c] / by_cat_n[c] for c in by_cat}
    add(B, "Which category has the lowest average transaction amount? Answer with the category name.", "text",
        min(avg_cat, key=avg_cat.get))
    add(B, "What is the largest single transaction amount? Round to 2 decimal places.", "number", r2(max(t["amount"] for t in tx)))
    for g in ["North", "South"]:
        add(B, f"What is the smallest transaction amount in the {g} region? Round to 2 decimal places.", "number",
            r2(min(t["amount"] for t in tx if t["region"] == g)))
    for th in [4000, 4900]:
        add(B, f"How many transactions have an amount greater than {th}?", "number", float(sum(1 for t in tx if t["amount"] > th)))
    for c, g in [("Food", "North"), ("Travel", "West"), ("Tools", "East")]:  # 3 filtered sums
        add(B, f"What is the total amount of {c} transactions in the {g} region? Round to 2 decimal places.", "number",
            r2(sum(t["amount"] for t in tx if t["category"] == c and t["region"] == g)))
    add(B, "How many distinct transaction dates are there in the Transactions sheet?", "number", float(len({t["date"] for t in tx})))
    add(B, "What is the total amount of reimbursed transactions? Round to 2 decimal places.", "number",
        r2(sum(t["amount"] for t in tx if t["reimbursed"])))
    y25 = [t for t in tx if t["date"].year == 2025]
    add(B, "What is the total amount of all transactions dated in 2025? Round to 2 decimal places.", "number",
        r2(sum(t["amount"] for t in y25)))
    add(B, "What is the average quantity (qty) per transaction? Round to 2 decimal places.", "number",
        r2(sum(t["qty"] for t in tx) / len(tx)))
    top3 = sorted(by_cat.items(), key=lambda kv: -kv[1])[2]
    add(B, "Ranking categories by total amount from highest to lowest, which category is third? Answer with the category name.",
        "text", top3[0])
    # Monthly sheet
    add(B, "In the Monthly sheet, what is the total planned amount for 2025?", "number",
        float(sum(m["planned"] for m in monthly if m["month"].year == 2025)))
    add(B, "In the Monthly sheet, in how many months was the actual amount higher than the planned amount?", "number",
        float(sum(1 for m in monthly if m["actual"] > m["planned"])))
    add(B, "In the Monthly sheet, what is the sum of the actual amounts for 2026?", "number",
        float(sum(m["actual"] for m in monthly if m["month"].year == 2026)))
    add(B, "In the Monthly sheet, what is the average planned amount per month? Round to 2 decimal places.", "number",
        r2(sum(m["planned"] for m in monthly) / len(monthly)))
    add(B, "In the Monthly sheet, what is the largest actual amount in any month?", "number", float(max(m["actual"] for m in monthly)))
    # Categories sheet
    for c in ["Insurance", "Training"]:
        add(B, f"In the Categories sheet, what is the budget for {c}?", "number",
            float(next(x["budget"] for x in cats if x["category"] == c)))
    for c in ["Rent", "Utilities"]:
        add(B, f"In the Categories sheet, who is the owner of the {c} category? Answer with the name only.", "text",
            next(x["owner"] for x in cats if x["category"] == c))
    add(B, "What is the total of all category budgets in the Categories sheet?", "number", float(sum(x["budget"] for x in cats)))
    add(B, "Which category in the Categories sheet has the largest budget? Answer with the category name.", "text",
        max(cats, key=lambda x: x["budget"])["category"])
    # notes.csv
    add(N, "What is the total of the amount column in notes.csv? Round to 2 decimal places.", "number", r2(sum(n["amount"] for n in notes)))
    add(N, "What is the average amount in notes.csv? Round to 2 decimal places.", "number",
        r2(sum(n["amount"] for n in notes) / len(notes)))
    places = sorted({n["place"] for n in notes})
    for p in places[:2]:
        add(N, f"How many rows in notes.csv have the place '{p}'?", "number", float(sum(1 for n in notes if n["place"] == p)))
    add(N, "In notes.csv, which item has the single largest amount? Answer with the item name.", "text",
        max(notes, key=lambda n: n["amount"])["item"])
    add(N, "What is the total amount in notes.csv for dates from 2026-03-01 to 2026-03-10 inclusive? Round to 2 decimal places.",
        "number", r2(sum(n["amount"] for n in notes if "2026-03-01" <= n["date"] <= "2026-03-10")))
    add(N, "What is the smallest amount in notes.csv? Round to 2 decimal places.", "number", r2(min(n["amount"] for n in notes)))
    by_place = defaultdict(float)
    for n in notes:
        by_place[n["place"]] += n["amount"]
    add(N, "In notes.csv, which place has the highest total amount? Answer with the place name.", "text",
        max(by_place, key=by_place.get))
    assert len(items) == 50, len(items)
    with open(os.path.join(office, "sheet-qa-50.jsonl"), "w") as f:
        for it in items:
            f.write(json.dumps(it, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(items)} items")


if __name__ == "__main__":
    main()
