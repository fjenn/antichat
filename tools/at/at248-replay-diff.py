#!/usr/bin/env python3
"""M7 at248-2: compares two `antichat-bench citations --stage pipeline-replay` reports over the same captured turns
(base code vs changed code) and lists every sentence whose citation changed: newly cited (or a source newly added to
its marker) and newly uncited. The newly cited ones are what an independent labeller must judge (no newly kept
unsupported sentence is allowed); the newly uncited ones are the supported sentences a change may cost.

  at248-replay-diff.py base.json new.json [--out diff.json] [--label-input label-input.jsonl]

--label-input writes the newly cited sentences with the cited sources' evidence (the text the answering model saw) in
the labeller's input format (item, qid, sentence, passage)."""
import json, re, sys


def marks(row):
    out = {}
    for m in row.get("final_markers", []):
        nums = set(int(x) for x in re.findall(r"\d+", m["marker"]))
        out.setdefault(m["claim"], set()).update(nums)
    return out


def main():
    args = sys.argv[1:]
    out = args[args.index("--out") + 1] if "--out" in args else None
    li = args[args.index("--label-input") + 1] if "--label-input" in args else None
    base, new = json.load(open(args[0])), json.load(open(args[1]))
    b = {r["id"]: r for r in base["rows"]}
    rows, gained, lost = [], 0, 0
    for r in new["rows"]:
        if r["id"] not in b:
            continue
        mb, mn = marks(b[r["id"]]), marks(r)
        ev = {}
        for claim, nums in mn.items():
            added = nums - mb.get(claim, set())
            if added:
                gained += 1
                rows.append({"id": r["id"], "change": "newly cited", "claim": claim, "sources": sorted(nums), "added": sorted(added)})
        for claim, nums in mb.items():
            if not mn.get(claim):
                lost += 1
                rows.append({"id": r["id"], "change": "newly uncited", "claim": claim, "sources": sorted(nums)})
    rep = {"base": args[0], "new": args[1], "answers": len(new["rows"]), "base_2_pills": base.get("runs_with_2_pills"),
           "new_2_pills": new.get("runs_with_2_pills"), "newly_cited": gained, "newly_uncited": lost, "rows": rows}
    if out:
        json.dump(rep, open(out, "w"), indent=2)
    if li:
        evidence = {}
        src = json.load(open(new["answers"]))
        for x in src.get("rows", src.get("runs", [])):
            d = x.get("diag", x)
            evidence[x.get("id", "run-%s" % x.get("run"))] = d.get("evidence", {})
        with open(li, "w") as f:
            k = 0
            for x in rows:
                if x["change"] != "newly cited":
                    continue
                k += 1
                ev = evidence.get(x["id"], {})
                passage = "\n\n".join("[%d] %s" % (n, ev.get(str(n), "")) for n in x["sources"])
                f.write(json.dumps({"item": "n%03d" % k, "qid": x["id"], "sentence": x["claim"], "passage": passage}) + "\n")
    print(json.dumps({k: v for k, v in rep.items() if k != "rows"}))


if __name__ == "__main__":
    main()
