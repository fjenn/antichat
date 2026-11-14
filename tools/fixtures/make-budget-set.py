#!/usr/bin/env python3
"""AT-270 fixtures (M6.T02): the whole-vs-excerpts decision set and the page-citation set.
  fixtures/docs/budget-40/doc-<NNN>p.pdf   40 PDFs, 1-300 pages (doc-020p and doc-300p included), reportlab invariant
  fixtures/docs/budget-40.expected.json    per doc: pages, tokens (chat-9b-q4 tokenizer over the page texts); per tier
                                           fixture T0-T4: context_tokens, prefill_tps, fixed chat tokens; the expected
                                           R-270 decision per doc x tier from the reference implementation below
  fixtures/docs/pagecite-100.jsonl         {doc, question, gold_pages, gold_answer}: 100 facts planted on known pages of
                                           the documents that exceed the T1 inline cap
  fixtures/docs/warm-10k.pdf + warm-10k-followups.jsonl (--warm, M6.T03 AT-279): pages until ≈ 10,000 tokens by the
                                           same tokenizer, 3 planted facts, 5 follow-up questions
Text: sentences from a fixed invented word list (seed 20261106; the packet's Gutenberg source needs a download, the
decision rule only needs real token counts), CC0. Planted facts are "The <noun> ledger code for <place> is <CODE>."
Tokens: `tokenizers` over the chat-9b-q4 tokenizer.json (--tokenizer; default the dev container's copy), else words*1.3.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-budget-set.py --out fixtures [--tokenizer <tokenizer.json>]
"""
from __future__ import annotations

import argparse
import io
import json
import math
import os
import random

SEED = 20261106
WORDS = ("harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel canal "
         "ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar willow").split()
PLACES = ("Ashford Brindle Calder Dunmore Elsworth Fenwick Garrow Halden Iverly Jessop Kelby Larkin Merrow Norbury "
          "Oakham Pendle Quarles Rothby Selwick Tamsin Ulgate Varden Whitby Yarrow Zennor").split()
PAGES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 22, 25, 28, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 110,
         120, 140, 160, 180, 200, 220, 240, 260, 280, 290, 300]
assert len(PAGES) == 40 and 20 in PAGES and 300 in PAGES

# Tier fixtures (fixed here; model-matrix tier pins at their default context, prefill_tps of the T1 measurement on
# chat-9b-q4 scaled by tier pp512 class). `fixed_tokens` = system + memory + tools; history empty.
TIERS = {
    "T0": {"context_tokens": 32768, "prefill_tps": 400, "fixed_tokens": 1200, "history_tokens": 0},
    "T1": {"context_tokens": 32768, "prefill_tps": 2000, "fixed_tokens": 1500, "history_tokens": 0},
    "T2": {"context_tokens": 65536, "prefill_tps": 2800, "fixed_tokens": 1500, "history_tokens": 0},
    "T3": {"context_tokens": 131072, "prefill_tps": 4000, "fixed_tokens": 1800, "history_tokens": 0},
    "T4": {"context_tokens": 262144, "prefill_tps": 6000, "fixed_tokens": 1800, "history_tokens": 0},
}


def decide(tokens: int, t: dict) -> dict:
    """R-270 AC1, the reference the Swift DocumentBudget must match: reservedAnswer = min(2048, 0.25 x ctx);
    freeContext = ctx - fixed - history - reservedAnswer; inline iff tokens <= min(0.5 x freeContext, prefill x 20)."""
    ctx = t["context_tokens"]
    reserved = min(2048, math.floor(0.25 * ctx))
    free = ctx - t["fixed_tokens"] - t["history_tokens"] - reserved
    fits_context = tokens <= 0.5 * free
    fits_time = tokens <= t["prefill_tps"] * 20
    return {"mode": "inline" if fits_context and fits_time else "excerpts", "fitsContext": fits_context,
            "fitsTime": fits_time, "estimateSeconds": math.ceil(tokens / t["prefill_tps"])}


def counter(path: str | None):
    if path and os.path.exists(path):
        from tokenizers import Tokenizer
        tok = Tokenizer.from_file(path)
        return (lambda s: len(tok.encode(s, add_special_tokens=False).ids)), os.path.basename(os.path.dirname(path))
    return (lambda s: round(len(s.split()) * 1.3)), "words*1.3"


def page_text(rng: random.Random, n_sentences: int = 26) -> list[str]:
    out = []
    for _ in range(n_sentences):
        out.append(" ".join(rng.choice(WORDS) for _ in range(rng.randint(9, 16))).capitalize() + ".")
    return out


def make_pdf(pages: list[list[str]]) -> bytes:
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=letter, invariant=1)
    for i, sentences in enumerate(pages, 1):
        t = c.beginText(54, 740)
        t.setFont("Helvetica", 9)
        line = ""
        for s in sentences:
            for w in s.split():
                if len(line) + len(w) + 1 > 105:
                    t.textLine(line)
                    line = w
                else:
                    line = f"{line} {w}".strip()
        if line:
            t.textLine(line)
        c.drawText(t)
        c.setFont("Helvetica", 8)
        c.drawString(300, 30, str(i))
        c.showPage()
    c.save()
    return buf.getvalue()


def make_warm(out: str, count) -> None:
    rng = random.Random(SEED + 1)
    pages, tokens = [], 0
    while tokens < 10_000:
        pages.append(page_text(rng))
        tokens += count(" ".join(pages[-1]))
    facts = []
    for p in (2, len(pages) // 2, len(pages)):
        code = f"W{rng.randint(100, 999)}{rng.choice('QRSTUVWXYZ')}"
        place = rng.choice(PLACES)
        pages[p - 1].insert(5, f"The harbour ledger code for {place} is {code}.")
        facts.append((p, place, code))
    with open(os.path.join(out, "docs", "warm-10k.pdf"), "wb") as f:
        f.write(make_pdf(pages))
    qs = [f"What is the harbour ledger code for {pl}?" for _, pl, _ in facts]
    qs += ["Which words appear most often in this document?", "Summarise the first page in one sentence."]
    with open(os.path.join(out, "docs", "warm-10k-followups.jsonl"), "w") as f:
        for q in qs:
            f.write(json.dumps({"question": q}) + "\n")
    print(f"warm-10k.pdf: {len(pages)} pages, {sum(count(' '.join(x)) for x in pages)} tokens")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--warm", action="store_true", help="only the M6.T03 warm-10k fixture")
    ap.add_argument("--tokenizer", default=os.path.expanduser(
        "~/Library/Application Support/AntiChat-Dev/Models/chat-9b-q4/tokenizer.json"))
    a = ap.parse_args()
    count, tok_name = counter(a.tokenizer)
    if a.warm:
        make_warm(a.out, count)
        return
    rng = random.Random(SEED)
    out_dir = os.path.join(a.out, "docs", "budget-40")
    os.makedirs(out_dir, exist_ok=True)
    docs, facts = [], []
    t1 = TIERS["T1"]
    t1_cap = min(0.5 * (t1["context_tokens"] - t1["fixed_tokens"] - min(2048, t1["context_tokens"] // 4)),
                 t1["prefill_tps"] * 20)
    used_codes: set[str] = set()
    for n in PAGES:
        name = f"doc-{n:03d}p.pdf"
        pages = [page_text(rng) for _ in range(n)]
        planted = []
        if n >= 35:  # candidates for the page-citation set (re-checked against the T1 cap below)
            for p in sorted(rng.sample(range(1, n + 1), 5)):
                while True:
                    code = f"{rng.choice('BCDFGHJKLMNPRSTVWXZ')}{rng.randint(100, 999)}{rng.choice('QRSTUVWXYZ')}"
                    if code not in used_codes:
                        used_codes.add(code)
                        break
                place = rng.choice(PLACES)
                noun = rng.choice(WORDS)
                pages[p - 1].insert(rng.randint(3, 20), f"The {noun} ledger code for {place} is {code}.")
                planted.append({"page": p, "noun": noun, "place": place, "code": code})
        tokens = sum(count(" ".join(s)) for s in pages)
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(make_pdf(pages))
        docs.append({"doc": name, "pages": n, "tokens": tokens})
        if tokens > t1_cap:
            for fct in planted:
                facts.append({"doc": f"budget-40/{name}",
                              "question": f"What is the {fct['noun']} ledger code for {fct['place']}?",
                              "gold_pages": [fct["page"]], "gold_answer": fct["code"]})
    rng.shuffle(facts)
    facts = facts[:100]
    assert len(facts) == 100, len(facts)
    expected = {
        "version": 1, "tokenizer": tok_name,
        "rule": "R-270 AC1: inline iff tokens <= min(0.5 x freeContext, prefill_tps x 20); freeContext = context_tokens - "
                "fixed_tokens - history_tokens - min(2048, 0.25 x context_tokens)",
        "tiers": TIERS,
        "docs": [{**d, "expected": {t: decide(d["tokens"], p) for t, p in TIERS.items()}} for d in docs],
    }
    with open(os.path.join(a.out, "docs", "budget-40.expected.json"), "w") as f:
        json.dump(expected, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(a.out, "docs", "pagecite-100.jsonl"), "w") as f:
        for x in facts:
            f.write(json.dumps(x, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
