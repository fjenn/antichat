#!/usr/bin/env python3
"""Write the M0.T04 bench prompts (fixtures/prompts/bench-*.txt) deterministically (stdlib only, CC0).

- bench-system.txt: a ~700-token system prompt (the cached, stable prefix of a 1K-context request).
- bench-300tok.txt: a ~300-token user message that asks for a long answer (≥ 256 generated tokens).
- bench-4k-doc.txt: a ~4,096-token invented document (prefill / C4); seed 20261030.
Token counts are approximate (≈ 0.75 words/token for Qwen-family BPE [ASSUMPTION]); the bench records
the engine-reported prompt token count of every run, which is the value used in the report.

Usage: python3 -I tools/fixtures/make-bench-prompts.py --out fixtures/prompts
"""
from __future__ import annotations

import argparse
import os
import random

SYSTEM_RULES = [
    "You are a careful, friendly assistant running entirely on the user's Mac.",
    "Answer in plain English. Prefer short paragraphs and concrete examples.",
    "When the user asks for a list, give a numbered list with one idea per item.",
    "When you are unsure, say so and explain what would settle the question.",
    "Do not invent sources. If you mention a fact that could be wrong, flag it.",
    "Use metric units first and give imperial units in brackets when helpful.",
    "Keep code blocks small and explain each block in one sentence before it.",
    "If the user writes in another language, answer in that language.",
    "Format dates as 30 October 2026 and times in 24-hour format.",
    "Never claim to browse the web unless a search tool result is in the conversation.",
]

TOPICS = ["tides", "glaciers", "coral reefs", "river deltas", "sand dunes", "monsoons", "volcanic islands", "kelp forests"]

WORDS = (
    "harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel "
    "canal ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar"
).split()


def system_prompt() -> str:
    parts = ["# Assistant guidelines", ""]
    for i in range(3):
        for r in SYSTEM_RULES:
            parts.append(f"- ({i + 1}.{SYSTEM_RULES.index(r) + 1}) {r}")
        parts.append("")
    return "\n".join(parts).strip() + "\n"


def user_prompt() -> str:
    lines = [
        "I am preparing a talk for a local science club and I would like your help with the main section.",
        "The audience are curious adults without a science background, so please avoid jargon or explain it.",
        "Please write a detailed explanation of how ocean tides work. Cover the pull of the Moon and the Sun,",
        "why most coasts see two high tides a day, what spring and neap tides are, why some places such as",
        "the Bay of Fundy have enormous tidal ranges while others barely notice the tide, and how tides affect",
        "harbours, fishing and coastal wildlife. Add a short paragraph on tidal power and its trade-offs.",
        "Use at least six paragraphs and finish with three questions the audience could discuss afterwards.",
        "Here are some notes from my own reading that you may use or correct:",
    ]
    rng = random.Random(7)
    notes = []
    for t in TOPICS[:4]:
        notes.append(f"- I read that {t} are shaped by forces that change over hours, seasons and centuries;"
                     f" a {rng.choice(WORDS)} keeper once told me the {rng.choice(WORDS)} by the {rng.choice(WORDS)} floods twice a day.")
    return "\n".join(lines + notes) + "\nPlease begin.\n"


def doc_4k() -> str:
    rng = random.Random(20261030)
    out = ["# The Harbour Ledger of Westmere (an invented town history)", ""]
    n = 0
    sec = 0
    while n < 3100:  # ≈ 3,100 words ≈ 4,100 tokens [ASSUMPTION]
        sec += 1
        out.append(f"## Section {sec}: the {rng.choice(WORDS)} and the {rng.choice(WORDS)}")
        for _ in range(4):
            sent = []
            for _ in range(rng.randint(4, 7)):
                w = [rng.choice(WORDS) for _ in range(rng.randint(3, 6))]
                year = rng.randint(1640, 1990)
                sent.append(f"In {year} the {w[0]} near the {w[1]} was rebuilt, and the {w[2]} recorded {rng.randint(2, 900)} {rng.choice(TOPICS)} entries"
                            + (f" beside the {w[3]}" if len(w) > 3 else "") + ".")
            para = " ".join(sent)
            n += len(para.split())
            out.append(para)
            out.append("")
    return "\n".join(out).strip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/prompts")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name, text in (("bench-system.txt", system_prompt()), ("bench-300tok.txt", user_prompt()), ("bench-4k-doc.txt", doc_4k())):
        p = os.path.join(a.out, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"[ok] {p} {len(text.split())} words")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
