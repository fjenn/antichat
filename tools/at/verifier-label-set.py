#!/usr/bin/env python3
"""M7 verifier: collects the newly cited sentences of pipeline-replay diffs (at248-replay-diff.py --label-input files)
into one labeller set, reusing earlier independent labels where the same sentence + passage was labelled before.

  verifier-label-set.py <out dir> <set>=<newly-cited.jsonl> ... [--prior <labels dir>:<labels-a.csv>,<labels-b.csv>] ...

Writes <out>/label-input.jsonl (item, sentence, passage; no set/qid: the labeller sees nothing else), <out>/key.json
(item -> set, qid, orig item) and <out>/prior.json (item -> the two earlier labels, when the pair was labelled before).
Run with python3 -I."""
import csv, json, sys
from pathlib import Path

args = sys.argv[1:]
out = Path(args.pop(0)); out.mkdir(parents=True, exist_ok=True)
priors = []
while "--prior" in args:
    i = args.index("--prior"); spec = args[i + 1]; del args[i:i + 2]
    d, files = spec.split(":"); priors.append((Path(d), files.split(",")))
known = {}
for d, files in priors:
    inp = {json.loads(l)["item"]: json.loads(l) for l in open(d / "label-input.jsonl")}
    labs = [{r["item"]: r["label"].strip().lower() for r in csv.DictReader(open(d / f))} for f in files]
    for k, x in inp.items():
        if all(k in l for l in labs):
            known[(x["sentence"], x["passage"])] = [l[k] for l in labs]
rows, key, prior = [], {}, {}
for spec in args:
    s, f = spec.split("=")
    for l in open(f):
        x = json.loads(l)
        item = "v%03d" % (len(rows) + 1)
        rows.append({"item": item, "sentence": x["sentence"], "passage": x["passage"]})
        key[item] = {"set": s, "qid": x["qid"], "orig_item": x["item"]}
        if (x["sentence"], x["passage"]) in known:
            prior[item] = known[(x["sentence"], x["passage"])]
with open(out / "label-input.jsonl", "w") as fo:
    for r in rows: fo.write(json.dumps(r, ensure_ascii=False) + "\n")
json.dump(key, open(out / "key.json", "w"), indent=1)
json.dump(prior, open(out / "prior.json", "w"), indent=1)
print(f"{len(rows)} items, {len(prior)} labelled before -> {out}")
