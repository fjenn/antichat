#!/usr/bin/env python3
"""AT-250 c2 (A-M7-T03c option c): independent labels for the cited sentences of a judged citations run.

  prep  <judged.json> <outdir> [--sample N --seed S]
        writes <outdir>/label-input.jsonl (item, qid, sentence, passage — no judge verdicts, no answer text) for the
        labeller, <outdir>/key.json (item → qid, sentence, judge) kept from it, and rubric.md. Default: every cited
        sentence (the full set, no sampling).
  score <outdir>
        reads <outdir>/labels.csv (item,label,reason) and prints supported/labelled (n/a excluded), the judge rate on
        the same items and judge–label agreement; writes <outdir>/score.json.
Run with python3 -I.
"""
import csv
import json
import random
import sys
from pathlib import Path

RUBRIC = Path(__file__).with_name("at250-rubric.md")


def split_sources(passage: str, ns: list) -> dict:
    """The per-source texts of a cited sentence's passage ("[n1] …\n\n[n2] …", bench order)."""
    out, rest = {}, passage
    for i, n in enumerate(ns):
        head = f"[{n}] "
        if not rest.startswith(head):
            return {}
        rest = rest[len(head):]
        if i + 1 < len(ns):
            k = rest.find(f"\n\n[{ns[i + 1]}] ")
            if k < 0:
                return {}
            out[n], rest = rest[:k], rest[k + 2:]
        else:
            out[n] = rest
    return out


def prep(judged: str, out: str, sample: int | None, seed: int, shards: int = 1) -> None:
    d = json.load(open(judged))
    items = []
    for r in d["rows"]:
        for c in r.get("cited", []):
            items.append({"qid": r["id"], "sentence": c["sentence"], "passage": c["passage"], "judge": c.get("judge"),
                          "n": c.get("n", [])})
    if sample and sample < len(items):
        items = sorted(random.Random(seed).sample(items, sample), key=lambda x: x["qid"])
    o = Path(out)
    o.mkdir(parents=True, exist_ok=True)
    with open(o / "label-input.jsonl", "w") as f:
        for i, it in enumerate(items, 1):
            f.write(json.dumps({"item": f"f{i:03d}", "qid": it["qid"], "sentence": it["sentence"], "passage": it["passage"]},
                               ensure_ascii=False) + "\n")
    json.dump([{"item": f"f{i:03d}", "qid": it["qid"], "sentence": it["sentence"], "judge": it["judge"]}
               for i, it in enumerate(items, 1)], open(o / "key.json", "w"), indent=1, ensure_ascii=False)
    (o / "rubric.md").write_text(RUBRIC.read_text())
    # grouped form for the labeller: per question, each cited source's text once, then the sentences with their [n]
    groups: dict = {}
    for i, it in enumerate(items, 1):
        g = groups.setdefault(it["qid"], {"qid": it["qid"], "sources": {}, "sentences": []})
        src = split_sources(it["passage"], it["n"]) or {"+".join(map(str, it["n"])): it["passage"]}
        for n, t in src.items():
            g["sources"][str(n)] = t
        g["sentences"].append({"item": f"f{i:03d}", "sentence": it["sentence"], "cites": [str(k) for k in src]})
    gl = list(groups.values())
    size = lambda g: sum(len(t) for t in g["sources"].values())
    total = sum(map(size, gl))
    shard, acc, k = [], 0, 1
    for g in gl:
        shard.append(g)
        acc += size(g)
        if acc >= total / shards * k and k < shards:
            json.dump(shard, open(o / f"grouped-{k}.json", "w"), indent=1, ensure_ascii=False)
            shard, k = [], k + 1
    if shard:
        json.dump(shard, open(o / f"grouped-{k}.json", "w"), indent=1, ensure_ascii=False)
    print(f"{len(items)} items, {len(gl)} questions, {total} source chars, {k} shard(s) → {o}")


def score(out: str) -> None:
    o = Path(out)
    key = {k["item"]: k for k in json.load(open(o / "key.json"))}
    labels = {r["item"]: r["label"].strip().lower() for r in csv.DictReader(open(o / "labels.csv"))}
    (o / "labels.tsv").write_text("".join(f"{k}\t{v}\n" for k, v in sorted(labels.items())))
    missing = sorted(set(key) - set(labels))
    used = [i for i in key if labels.get(i) in ("supported", "partial", "unsupported")]
    sup = sum(labels[i] == "supported" for i in used)
    judged = [i for i in used if key[i]["judge"] in ("yes", "no")]
    agree = sum((key[i]["judge"] == "yes") == (labels[i] == "supported") for i in judged)
    jy_ln = sum(key[i]["judge"] == "yes" and labels[i] != "supported" for i in judged)
    jn_ly = sum(key[i]["judge"] == "no" and labels[i] == "supported" for i in judged)
    res = {"items": len(key), "labelled": len(used), "na": sum(labels.get(i) == "n/a" for i in key), "missing": missing,
           "supported": sup, "ratio": sup / max(len(used), 1), "bar": 0.90, "pass": sup / max(len(used), 1) >= 0.90 and not missing,
           "judge_yes": sum(key[i]["judge"] == "yes" for i in judged), "judge_items": len(judged),
           "agreement": agree / max(len(judged), 1), "judge_yes_label_no": jy_ln, "judge_no_label_yes": jn_ly,
           "counts": {l: sum(v == l for v in labels.values()) for l in set(labels.values())}}
    json.dump(res, open(o / "score.json", "w"), indent=1)
    print(json.dumps(res))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "prep":
        n = int(a[a.index("--sample") + 1]) if "--sample" in a else None
        s = int(a[a.index("--seed") + 1]) if "--seed" in a else 11
        k = int(a[a.index("--shards") + 1]) if "--shards" in a else 1
        prep(a[1], a[2], n, s, k)
    else:
        score(a[1])
