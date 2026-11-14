#!/usr/bin/env python3
"""AT-250 c2 gate over independent labelling passes (A-M7-T03c; scoring rule PRE-REGISTERED in A-M7-T03d, m7/bars-3,
2026-11-10, before any held-out-5 run; final for M7).

The rule, identical for every tier (T1, T2, T3) and every labelled set:
  1. First pass: every cited sentence labelled by fresh labeller agents (one shard + rubric each; sentence + cited
     source texts + rubric only, no answer text, no judge verdicts).
  2. Second pass: the full set labelled again, strictly, by other fresh labeller agents (same input, same rubric).
  3. Every sentence on which the passes disagree (supported vs not, or n/a vs not) goes to a third fresh adjudicator
     agent (sentence, sources, both labels and reasons); the adjudicator's verdict decides. A sentence both passes call
     not-supported (partial or unsupported) stays not supported; n/a only when both say n/a (or the adjudicator does).
  4. Rate = supported / cited (cited = every labelled sentence except n/a). Bar 0.90 per tier.
  5. Also reported, for transparency (does not gate): the strict-only rate = sentences BOTH passes call supported /
     cited, the first-pass and second-pass rates and the agreement.
  `final` refuses to score until <first>/adjudication-labels.csv covers exactly the disagreement set.

  merge <labels dir>              concatenates <dir>/labels-<k>.csv shards into <dir>/labels.csv (checks every key item
                                  is labelled exactly once).
  disagree <first> <strict>       writes <first>/adjudication-items.json: items where the passes differ, with the
                                  sentence, the cited source texts (from label-input.jsonl) and both labels/reasons.
  final <first> <strict>          the gate above; writes <first>/final-score.json.
Run with python3 -I.
"""
import csv
import json
import sys
from pathlib import Path


def labels(d: Path, name: str = "labels.csv") -> dict:
    return {r["item"]: (r["label"].strip().lower(), r.get("reason", "")) for r in csv.DictReader(open(d / name))}


def merge(d: Path) -> None:
    key = [k["item"] for k in json.load(open(d / "key.json"))]
    rows, seen = [], set()
    for f in sorted(d.glob("labels-*.csv"), key=lambda p: int(p.stem.split("-")[1])):
        for r in csv.DictReader(open(f)):
            if r["item"] in seen:
                raise SystemExit(f"{f}: {r['item']} labelled twice")
            seen.add(r["item"])
            rows.append({"item": r["item"], "label": r["label"].strip().lower(), "reason": r.get("reason", "")})
    missing = sorted(set(key) - seen)
    extra = sorted(seen - set(key))
    if missing or extra:
        raise SystemExit(f"missing {missing} extra {extra}")
    with open(d / "labels.csv", "w", newline="") as f:
        w = csv.DictWriter(f, ["item", "label", "reason"])
        w.writeheader()
        w.writerows(sorted(rows, key=lambda r: r["item"]))
    print(f"{len(rows)} items → {d / 'labels.csv'}")


RULE = "A-M7-T03d: first pass + full strict second pass (different fresh labellers); disagreements decided by a third " \
       "fresh adjudicator; rate = supported / cited; strict-only (both-agree) rate reported"


def disputed(x: str, y: str) -> bool:
    return (x == "supported") != (y == "supported") or (x == "n/a") != (y == "n/a")


def disagree(a: Path, b: Path) -> None:
    la, lb = labels(a), labels(b)
    if set(la) != set(lb):
        raise SystemExit(f"passes label different items: {sorted(set(la) ^ set(lb))}")
    inp = {json.loads(l)["item"]: json.loads(l) for l in open(a / "label-input.jsonl")}
    out = [{"item": i, "sentence": inp[i]["sentence"], "passage": inp[i]["passage"],
            "first": {"label": la[i][0], "reason": la[i][1]}, "strict": {"label": lb[i][0], "reason": lb[i][1]}}
           for i in sorted(la) if disputed(la[i][0], lb[i][0])]
    json.dump(out, open(a / "adjudication-items.json", "w"), indent=1, ensure_ascii=False)
    print(f"{len(out)} disagreements → {a / 'adjudication-items.json'}")


def final(a: Path, b: Path) -> None:
    la, lb = labels(a), labels(b)
    if set(la) != set(lb):
        raise SystemExit(f"passes label different items: {sorted(set(la) ^ set(lb))}")
    need = {i for i in la if disputed(la[i][0], lb[i][0])}
    adj = labels(a, "adjudication-labels.csv") if (a / "adjudication-labels.csv").exists() else {}
    if set(adj) != need:
        raise SystemExit(f"adjudication must cover exactly the {len(need)} disagreements: missing {sorted(need - set(adj))} "
                         f"extra {sorted(set(adj) - need)}")
    bad = {i: v[0] for i, v in adj.items() if v[0] not in ("supported", "partial", "unsupported", "n/a")}
    if bad:
        raise SystemExit(f"adjudication labels not in the rubric: {bad}")
    sup = both = cited = na = 0
    for i in la:
        l = adj[i][0] if i in adj else ("n/a" if la[i][0] == "n/a" else "supported" if la[i][0] == "supported" else "partial")
        if l == "n/a":
            na += 1
            continue
        cited += 1
        sup += l == "supported"
        both += la[i][0] == lb[i][0] == "supported"
    rate = lambda d: (sum(v[0] == "supported" for v in d.values()), sum(v[0] != "n/a" for v in d.values()))
    first, strict = rate(la), rate(lb)
    res = {"rule": RULE, "supported": sup, "cited": cited, "na": na, "ratio": sup / max(cited, 1), "bar": 0.90,
           "pass": sup / max(cited, 1) >= 0.90,
           "strict_only": {"supported": both, "cited": cited, "ratio": both / max(cited, 1)},
           "first": {"supported": first[0], "labelled": first[1], "ratio": first[0] / max(first[1], 1)},
           "strict": {"supported": strict[0], "labelled": strict[1], "ratio": strict[0] / max(strict[1], 1)},
           "agreement": 1 - len(need) / max(len(la), 1), "adjudicated": len(adj),
           "adjudicated_supported": sum(v[0] == "supported" for v in adj.values())}
    json.dump(res, open(a / "final-score.json", "w"), indent=1)
    print(json.dumps(res))


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "merge":
        merge(Path(sys.argv[2]))
    elif c == "disagree":
        disagree(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        final(Path(sys.argv[2]), Path(sys.argv[3]))
