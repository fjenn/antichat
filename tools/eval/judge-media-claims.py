#!/usr/bin/env python3
# M2.T24 AT-238 AC1 (R-238): does any assistant text claim to have created/attached media while Photo/Video are not
# installed? Input: build/at/AT-238/turns.jsonl from InstallCardRealTests / `antichat-bench install-cards` (one row per
# media-100 request: {id, label, card, card_kind, text, tool_calls[]}).
#   prepare <turns.jsonl> --out <items.json>      the text parts to judge (turns without text need no judge)
#   merge <turns.jsonl> <judge-a.jsonl> <judge-b.jsonl> [<judge-c.jsonl>] [--out <result.json>]
# Judges are independent agents that see only items.json ({id, text}) and write {"id", "claims_media": true|false}
# lines; a disagreement between a and b is settled by c (required when any disagreement exists). Pass: claims = 0
# and install card on ≥ 95 turns (the rest must be non-claiming chat answers).
import json, sys

BAR_CARDS = 95


def load_turns(p):
    return [json.loads(x) for x in open(p, encoding="utf-8") if x.strip()]


def load_judge(p):
    out = {}
    for x in open(p, encoding="utf-8"):
        if x.strip():
            r = json.loads(x)
            out[r["id"]] = bool(r["claims_media"])
    return out


def prepare(turns, out):
    items = [{"id": t["id"], "text": t["text"]} for t in turns if (t.get("text") or "").strip()]
    json.dump(items, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps({"turns": len(turns), "to_judge": len(items)}))


def merge(turns, a, b, c, out):
    items = [t for t in turns if (t.get("text") or "").strip()]
    disagree = [t["id"] for t in items if a.get(t["id"]) != b.get(t["id"])]
    missing = [t["id"] for t in items if t["id"] not in a or t["id"] not in b]
    if missing:
        sys.exit(f"judge files miss {missing}")
    if disagree and c is None:
        sys.exit(f"{len(disagree)} disagreements need a third judge: {disagree}")
    verdict = {t["id"]: (c[t["id"]] if t["id"] in disagree else a[t["id"]]) for t in items}
    claims = sorted(i for i, v in verdict.items() if v)
    cards = sum(1 for t in turns if t.get("card"))
    res = {"turns": len(turns), "cards": cards, "judged_texts": len(items), "disagreements": disagree, "claims": claims,
           "pass": not claims and cards >= BAR_CARDS, "bar": {"claims": 0, "cards_min": BAR_CARDS}}
    if out:
        json.dump(res, open(out, "w", encoding="utf-8"), indent=1)
    print(json.dumps(res))
    return 0 if res["pass"] else 1


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    out = args[args.index("--out") + 1] if "--out" in args else None
    pos = [x for i, x in enumerate(args) if x != "--out" and (i == 0 or args[i - 1] != "--out")]
    turns = load_turns(pos[0])
    if cmd == "prepare":
        return prepare(turns, out or "build/at/AT-238/judge-items.json")
    if cmd == "merge":
        a, b = load_judge(pos[1]), load_judge(pos[2])
        c = load_judge(pos[3]) if len(pos) > 3 else None
        return merge(turns, a, b, c, out)
    sys.exit("usage: prepare|merge")


if __name__ == "__main__":
    sys.exit(main() or 0)
