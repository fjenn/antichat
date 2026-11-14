#!/usr/bin/env python3
"""AT-250 c2 attempt 5 (A-M7-T03c): replays the attempt-5 additions to CitationGrounding (recency + release-stage
checks; Swift: Packages/Tools/Sources/AntiChatTools/Search/Citations/CitationGrounding.swift, same word lists) on an
already labelled run. Both checks are deterministic, run after generation and only remove markers, so the labels of the
sentences that keep their marker are unchanged: the replay is the supported share the app would show.
  python3 -I tools/at/at250-replay.py <labels dir> [<judged.json>]   (labels dir: label-input.jsonl + labels.csv)
"""
import csv
import json
import re
import sys
from pathlib import Path

RECENCY_CLAIMS = ["latest", "most recent", "newest", "current", "currently", "next", "upcoming"]
RECENCY = ["latest", "most recent", "newest", "recent", "recently", "current", "currently", "next", "upcoming"]
RC = ["release candidate", "rc", "rc1", "rc2", "rc3"]
STAGES = [("alpha", ["alpha"]), ("beta", ["beta"]), ("preview", ["preview"]), ("release candidate", RC), ("rc", RC)]


def has(w: str, text: str) -> bool:
    return re.search(r"\b" + re.escape(w) + r"\b", text, re.I) is not None


WINDOW = 150


def recency_backed(sentence: str, passage: str) -> bool:
    nums = [n.rstrip(".,") for n in re.findall(r"\d+(?:[.,]\d+)*", re.sub(r"(?<=\d),(?=\d{3})", "", sentence.lower()))]
    pats = [r"(?<![\d.,])" + re.escape(n) + r"(?![\d]|[.,]\d)" for n in nums]
    if not pats:
        toks = re.findall(r"[^\W_][\w'\-]*", sentence)
        pats = [r"\b" + re.escape(t.lower()) + r"\b" for i, t in enumerate(toks) if i > 0 and t[0].isupper() and len(t) >= 3]
    if not pats:
        return any(has(w, passage) for w in RECENCY)
    for pt in pats:
        for m in re.finditer(pt, passage, re.I):
            seg = passage[max(0, m.start() - WINDOW):m.end() + WINDOW]
            if any(has(w, seg) for w in RECENCY):
                return True
    return False


QUALIFIERS = ["main", "mainly", "primarily", "primary", "sole", "solely", "only", "first", "largest", "biggest", "smallest",
              "best", "steadily", "always", "never", "widely", "often", "commonly", "usually", "decades", "entirely",
              "completely", "fully", "exclusively", "leading", "dominant", "prevalent", "decisive", "invisible",
              "frictionless", "thinnest", "strongest", "fastest", "oldest", "newest", "highest", "lowest"]
ANCHOR_STOP = set("which where there their about these those while other being after before during under first through between".split())


def qualifier_backed(q: str, sentence: str, passage: str) -> bool:
    toks = re.findall(r"[^\W_][\w'\-]*", sentence)
    anchors = [re.escape(n) for n in re.findall(r"\d+(?:[.,]\d+)*", sentence)]
    anchors += [r"\b" + re.escape(t) + r"\b" for i, t in enumerate(toks)
                if (i > 0 and t[0].isupper() and len(t) >= 3) or (len(t) >= 6 and t.lower() not in ANCHOR_STOP and t.lower() not in QUALIFIERS)]
    for a in anchors:
        for m in re.finditer(a, passage, re.I):
            if has(q, passage[max(0, m.start() - WINDOW):m.end() + WINDOW]):
                return True
    return False


def drops(sentence: str, passage: str) -> list:
    c, p = sentence.lower(), passage.lower()
    lack = []
    if any(has(w, c) for w in RECENCY_CLAIMS) and not recency_backed(sentence, passage):
        lack.append("recency")
    lack += [f"qualifier {q}" for q in QUALIFIERS if has(q, c) and not qualifier_backed(q, sentence, passage)]
    for term, forms in STAGES:
        if has(term, c) and not any(has(f, p) for f in forms):
            lack.append(term)
    return lack


def main(d: str) -> None:
    o = Path(d)
    inp = [json.loads(l) for l in open(o / "label-input.jsonl")]
    lab = {r["item"]: r["label"].strip().lower() for r in csv.DictReader(open(o / "labels.csv"))}
    kept, dropped = [], []
    for it in inp:
        why = drops(it["sentence"], it["passage"])
        (dropped if why else kept).append((it["item"], lab.get(it["item"]), why, it["sentence"][:90]))
    used = [k for k in kept if k[1] in ("supported", "partial", "unsupported")]
    sup = sum(k[1] == "supported" for k in used)
    res = {"items": len(inp), "dropped_by_new_checks": len(dropped),
           "dropped_labels": {l: sum(x[1] == l for x in dropped) for l in {x[1] for x in dropped}},
           "kept_labelled": len(used), "kept_supported": sup, "ratio": sup / max(len(used), 1),
           "pass": sup / max(len(used), 1) >= 0.90, "dropped": dropped}
    json.dump(res, open(o / "replay-attempt5.json", "w"), indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in res.items() if k != "dropped"}))
    for x in dropped:
        print("  dropped", x)


if __name__ == "__main__":
    main(sys.argv[1])
