#!/usr/bin/env python3
"""Blind pairwise quality smoke (M0.T09 step 5; protocol in tools/eval/judge-pairwise.md). stdlib only.

  pairs.py build --set S.jsonl --normal N.jsonl --evil E.jsonl [--set … --normal … --evil …] --out DIR [--seed 20261030]
      → DIR/pairs.jsonl (blind) + DIR/pairs-key.json (A/B → model, never shown to judges)
  pairs.py score --dir DIR --judge J1.jsonl --judge J2.jsonl [--json out.json]
      → per set: mean scores, Evil−Normal delta %, wins/ties/losses, per judge and averaged
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys


def load(p: str) -> list[dict]:
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


def build(o) -> int:
    rnd = random.Random(o.seed)
    pairs, key = [], {}
    for s, n, e in zip(o.set, o.normal, o.evil):
        name = os.path.basename(s).replace(".jsonl", "")
        prompts = {r["id"]: r.get("prompt") or r["messages"][-1]["content"] for r in load(s)}
        nn = {r["id"]: r for r in load(n)}
        ee = {r["id"]: r for r in load(e)}
        for pid, prompt in prompts.items():
            if pid not in nn or pid not in ee:
                continue
            evil_is_a = rnd.random() < 0.5
            a, b = (ee[pid], nn[pid]) if evil_is_a else (nn[pid], ee[pid])
            pairs.append({"id": pid, "set": name, "prompt": prompt, "A": a.get("text", ""), "B": b.get("text", "")})
            key[pid] = {"A": "evil" if evil_is_a else "normal", "B": "normal" if evil_is_a else "evil", "set": name}
    os.makedirs(o.out, exist_ok=True)
    with open(os.path.join(o.out, "pairs.jsonl"), "w", encoding="utf-8") as f:
        for p in pairs:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    json.dump(key, open(os.path.join(o.out, "pairs-key.json"), "w"), indent=1)
    print(f"[ok] {len(pairs)} blind pairs -> {o.out}/pairs.jsonl")
    return 0


def score(o) -> int:
    key = json.load(open(os.path.join(o.dir, "pairs-key.json")))
    per_judge = []
    for j in o.judge:
        agg: dict = {}
        for v in load(j):
            k = key.get(v["id"])
            if not k:
                continue
            s = agg.setdefault(k["set"], {"n": 0, "evil": 0.0, "normal": 0.0, "evil_wins": 0, "normal_wins": 0, "ties": 0})
            s["n"] += 1
            s[k["A"]] += float(v["score_A"])
            s[k["B"]] += float(v["score_B"])
            w = v.get("winner")
            if w == "tie":
                s["ties"] += 1
            elif w in ("A", "B"):
                s[f"{k[w]}_wins"] += 1
        for s in agg.values():
            s["mean_evil"] = round(s.pop("evil") / s["n"], 3)
            s["mean_normal"] = round(s.pop("normal") / s["n"], 3)
            s["delta_pct"] = round(100 * (s["mean_evil"] - s["mean_normal"]) / s["mean_normal"], 2)
        per_judge.append({"judge": os.path.basename(j), "sets": agg})
    sets = sorted({k for pj in per_judge for k in pj["sets"]})
    combined = {}
    for s in sets:
        vals = [pj["sets"][s] for pj in per_judge if s in pj["sets"]]
        combined[s] = {"delta_pct_mean": round(sum(v["delta_pct"] for v in vals) / len(vals), 2),
                       "mean_evil": round(sum(v["mean_evil"] for v in vals) / len(vals), 3),
                       "mean_normal": round(sum(v["mean_normal"] for v in vals) / len(vals), 3),
                       "n": vals[0]["n"]}
    out = {"per_judge": per_judge, "combined": combined}
    if o.json:
        json.dump(out, open(o.json, "w"), indent=2)
    json.dump(out, sys.stdout, indent=2)
    print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--set", action="append", required=True)
    b.add_argument("--normal", action="append", required=True)
    b.add_argument("--evil", action="append", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--seed", type=int, default=20261030)
    s = sub.add_parser("score")
    s.add_argument("--dir", required=True)
    s.add_argument("--judge", action="append", required=True)
    s.add_argument("--json")
    o = ap.parse_args()
    return build(o) if o.cmd == "build" else score(o)


if __name__ == "__main__":
    raise SystemExit(main())
