#!/usr/bin/env python3
"""Score tool calls from `AntiChat -Bench agentic` (M0.T09 step 3). stdlib only; run with `python3 -I`.

A task's call is VALID when its first tool call (a) has arguments that parse as a JSON object, (b) names a
tool offered in the task, and (c) validates against that tool's JSON schema (type, required, properties,
enum, items, minimum/maximum; the subset our fixtures use). EXPECTED additionally needs the expected tool
name and every `args_contains` substring ("a|b" = any of, case-insensitive). A task with no call is invalid.

Usage: agentic.py --set agentic-30.jsonl --raw RAW.jsonl [--raw RAW2.jsonl …] [--csv out.csv] [--json out.json]
"""
from __future__ import annotations

import argparse
import csv
import json
import sys


def validate(v, schema: dict, path: str = "$") -> list[str]:
    errs: list[str] = []
    t = schema.get("type")
    types = {"object": dict, "array": list, "string": str, "boolean": bool}
    if t in types and not isinstance(v, types[t]):
        return [f"{path}: expected {t}"]
    if t == "integer" and (isinstance(v, bool) or not (isinstance(v, int) or (isinstance(v, float) and v.is_integer()))):
        return [f"{path}: expected integer"]
    if t == "number" and (isinstance(v, bool) or not isinstance(v, (int, float))):
        return [f"{path}: expected number"]
    if "enum" in schema and v not in schema["enum"]:
        errs.append(f"{path}: {v!r} not in enum")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        if "minimum" in schema and v < schema["minimum"]:
            errs.append(f"{path}: < minimum")
        if "maximum" in schema and v > schema["maximum"]:
            errs.append(f"{path}: > maximum")
    if t == "object":
        for r in schema.get("required", []):
            if r not in v:
                errs.append(f"{path}: missing {r}")
        props = schema.get("properties", {})
        for k, sub in props.items():
            if k in v:
                errs += validate(v[k], sub, f"{path}.{k}")
    if t == "array" and "items" in schema:
        for i, x in enumerate(v):
            errs += validate(x, schema["items"], f"{path}[{i}]")
    return errs


def score(task: dict, row: dict) -> dict:
    tools = {t["function"]["name"]: t["function"].get("parameters", {}) for t in task["tools"]}
    calls = row.get("tool_calls") or []
    out = {"id": task["id"], "category": task["category"], "n_calls": len(calls), "name": "", "valid": False,
           "expected": False, "why": ""}
    if row.get("error"):
        out["why"] = f"error: {row['error']}"[:200]
        return out
    if not calls:
        out["why"] = "no tool call; text: " + (row.get("text") or "")[:120].replace("\n", " ")
        return out
    c = calls[0]
    out["name"] = c.get("name", "")
    try:
        args = json.loads(c.get("arguments") or "{}")
    except json.JSONDecodeError as e:
        out["why"] = f"arguments not JSON: {e}"
        return out
    if not isinstance(args, dict):
        out["why"] = "arguments not an object"
        return out
    if out["name"] not in tools:
        out["why"] = f"unknown tool {out['name']!r}"
        return out
    errs = validate(args, tools[out["name"]])
    if errs:
        out["why"] = "; ".join(errs)[:200]
        return out
    out["valid"] = True
    exp = task["expected"]
    ok = out["name"] == exp["name"]
    for k, want in exp.get("args_contains", {}).items():
        got = json.dumps(args.get(k, ""), ensure_ascii=False).lower()
        if not any(w.lower() in got for w in want.split("|")):
            ok = False
            out["why"] = f"{k}={args.get(k)!r} lacks {want!r}"
    out["expected"] = ok
    out["args"] = json.dumps(args, ensure_ascii=False)[:300]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--raw", action="append", required=True)
    ap.add_argument("--csv")
    ap.add_argument("--json")
    o = ap.parse_args()
    tasks = {t["id"]: t for t in (json.loads(l) for l in open(o.set, encoding="utf-8") if l.strip())}
    summary, rows = {}, []
    for raw in o.raw:
        runs = [json.loads(l) for l in open(raw, encoding="utf-8") if l.strip()]
        if not runs:
            continue
        label = f"{runs[0].get('model')}|thinking={'on' if runs[0].get('thinking') else 'off'}"
        scored = [score(tasks[r["id"]], r) | {"run": label} for r in runs if r.get("id") in tasks]
        rows += scored
        n = len(scored)
        summary[label] = {"n": n, "valid": sum(s["valid"] for s in scored), "expected": sum(s["expected"] for s in scored),
                          "valid_rate": round(sum(s["valid"] for s in scored) / n, 4) if n else 0,
                          "expected_rate": round(sum(s["expected"] for s in scored) / n, 4) if n else 0}
    if o.csv:
        with open(o.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["run", "id", "category", "n_calls", "name", "valid", "expected", "why", "args"])
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k in w.fieldnames})
    if o.json:
        json.dump(summary, open(o.json, "w"), indent=2)
    json.dump(summary, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
