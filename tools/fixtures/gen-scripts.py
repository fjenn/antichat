#!/usr/bin/env python3
"""ScriptedEngine fixture scripts (M1.T05 step 6; format in
Packages/EngineProtocol/Sources/AntiChatEngineProtocol/EngineScript.swift). Deterministic, stdlib only.

  python3 -I tools/fixtures/gen-scripts.py --out fixtures/scripts         # write
  python3 -I tools/fixtures/gen-scripts.py --out fixtures/scripts --check # verify the committed copies

All text is authored here (CC0). Scripts: basic, stream-600w, tool-call, reasoning, crash-mid-stream, slow-load,
s2, tool-loop-runaway + tool-approval (M1.T16), long-context (M1.T18), no-reasoning (M1.T15), mixed-3k (M1.T09), regen (M1.T10),
vq-chat + vq-voice (visual QA legs vq-m9 and vq-m3: replies that match the prompts the probes send).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

WORDS = (
    "The quiet harbour town wakes slowly. Fishing boats knock against the pier while gulls argue over the "
    "morning catch. A baker props the door open so the smell of warm bread drifts down the lane, and the "
    "first ferry sounds its horn across the grey water. People walk with their collars up, nodding to "
    "neighbours they have known for years. By nine the market square fills with crates of apples, jars of "
    "honey and bundles of dried lavender. Children chase each other between the stalls until a parent "
    "calls them back. An old man sets up a folding chair beside the fountain and reads yesterday's paper "
    "as if the news might still change. Out on the headland the lighthouse keeper checks the lamp, though "
    "it has run on its own for decades. Clouds break apart around noon and the sea turns from slate to "
    "green. Tourists arrive on the second ferry with cameras and maps, asking directions to the castle "
    "ruins on the hill."
).split()


def line(**kw) -> str:
    return json.dumps(kw, ensure_ascii=False, separators=(",", ":"))


def words(n: int, delay: int) -> list[str]:
    out = []
    for i in range(n):
        w = WORDS[i % len(WORDS)]
        out.append(line(t="textDelta", v=(w if i == 0 else " " + w), delayMs=delay))
    return out


def tokens_of(text: str, delay: int, kind: str = "textDelta") -> list[str]:
    parts = text.split(" ")
    return [line(t=kind, v=(p if i == 0 else " " + p), delayMs=delay) for i, p in enumerate(parts)]


S2_REPLY = (
    "## A weekend in Lisbon\n\nHere is a relaxed plan:\n\n1. **Saturday morning:** walk through Alfama and "
    "stop at a miradouro for the view.\n2. **Saturday afternoon:** ride tram 28, then pastéis de nata in "
    "Belém.\n3. **Sunday:** the Gulbenkian museum and a long lunch.\n\nA packing list as code:\n\n```python\n"
    "packing = [\"comfortable shoes\", \"light jacket\", \"sunscreen\"]\nfor item in packing:\n    print(item)\n"
    "```\n\nWant restaurant ideas too?"
)


VQ_CHAT = [
    ("harbour town", (
        "## A relaxed weekend by the harbour\n\nKeep it slow and close to the water:\n\n1. **Saturday morning:** "
        "coffee on the quay while the fishing boats come in, then a walk out to the lighthouse.\n2. **Saturday "
        "afternoon:** browse the market square and take the short ferry ride around the bay.\n3. **Sunday:** a "
        "late breakfast, the castle ruins on the hill, and a long lunch before you head home.\n\n| When | Plan |\n"
        "|---|---|\n| Sat AM | Quay and lighthouse |\n| Sat PM | Market and ferry |\n| Sun | Castle and lunch |\n\n"
        "Want me to suggest places to eat?"), 15),
    ("fishing village", (
        "## A quiet weekend in a fishing village\n\nA smaller place suits a slower pace:\n\n1. **Saturday:** watch "
        "the morning catch land, then follow the cliff path to the next cove.\n2. **Saturday evening:** grilled "
        "fish at the harbour inn and a walk along the breakwater at sunset.\n3. **Sunday:** borrow a kayak if the "
        "sea is calm, or read on the beach until the afternoon bus.\n\nShall I add a rainy-day backup?"), 15),
    ("pack for the coast", (
        "For the coast in April, pack for sun, wind and a shower or two:\n\n- **Layers:** a light waterproof "
        "jacket, a warm jumper and a couple of T-shirts\n- **Shoes:** comfortable walking shoes with good grip, "
        "plus sandals for the evenings\n- **Extras:** sunglasses, sunscreen, a small umbrella and a reusable "
        "water bottle\n\nThe sea is still cold in April, so a swimsuit is optional."), 15),
    ("seafood", (
        "Three seafood dishes worth trying:\n\n1. **Grilled sardines:** simply salted and charred, served on "
        "bread.\n2. **Clams in white wine:** cooked with garlic and coriander; ask for extra bread for the "
        "sauce.\n3. **Seafood rice:** a soupy rice with prawns, mussels and squid, made for sharing.\n\nIf you "
        "only try one, make it the grilled sardines."), 15),
    ("2+2", (
        "2 + 2 = 4. Start at 2 and count up two more: 3, then 4. It is also 2 × 2, so for the number 2 adding it "
        "to itself and multiplying it by itself give the same answer."), 40),
]

VQ_VOICE_REPLY = (
    "For a spring weekend in Lisbon, pack light layers:\n\n- **Clothes:** T-shirts, a light jumper for the "
    "evenings and a thin rain jacket\n- **Shoes:** comfortable walking shoes with good grip, as the hills and "
    "cobbles are steep\n- **Extras:** sunglasses, sunscreen and a small day bag\n\nSpring days are mild, but the "
    "wind off the river can be cool after sunset."
)


def mixed_3k() -> str:
    """~3,000-token reply with headings, lists, code, a table and LaTeX (M1.T09 AT-008 leg 4, NFR-U5)."""
    prose = " ".join(WORDS)
    code = "\n".join(
        ["```python", "from dataclasses import dataclass", "", "", "@dataclass", "class Stall:", "    name: str",
         "    crates: int", "    price: float", "", "    def revenue(self) -> float:",
         "        return self.crates * self.price", "", "",
         "def market(stalls: list[Stall]) -> dict[str, float]:", "    totals = {}", "    for s in stalls:",
         "        totals[s.name] = round(s.revenue(), 2)", "    return dict(sorted(totals.items()))", "", "",
         "if __name__ == \"__main__\":", "    day = [Stall(\"apples\", 12, 3.5), Stall(\"honey\", 4, 8.0),",
         "           Stall(\"lavender\", 9, 2.25)]", "    for name, total in market(day).items():",
         "        print(f\"{name:>10}: {total:8.2f}\")", "```"])
    table = "\n".join(
        ["| Stall | Crates | Price | Revenue |", "|---|---:|---:|---:|", "| Apples | 12 | 3.50 | 42.00 |",
         "| Honey | 4 | 8.00 | 32.00 |", "| Lavender | 9 | 2.25 | 20.25 |", "| **Total** | 25 | | **94.25** |"])
    parts = ["# A market day, in numbers", "", prose, "", "## What the stalls sold", "", prose, "", table, "",
             "The revenue of a stall is $r = c \\cdot p$, crates times price, and the day's total is", "",
             "$$\n\\sum_{i=1}^{n} c_i \\, p_i = 94.25\n$$", "", "## Counting it in code", "", prose, "", code, "",
             "## Notes", "", "- " + prose[:300], "- " + prose[300:600], "- " + prose[600:900], ""]
    for k in range(9):
        parts += [f"### Afternoon {k + 1}", "", prose, ""]
        if k % 3 == 1:
            parts += ["With the average price $\\bar{p} = \\frac{1}{n}\\sum_i p_i$ the estimate holds.", ""]
    return "\n".join(parts).strip() + "\n\nThat is the whole day."


def scripts() -> dict[str, list[str]]:
    s: dict[str, list[str]] = {}
    # M1.T19: `title` = the answer to a TitleService request (anywhere in the script; never a play).
    s["basic"] = ["# Short greeting, then done (M1.T07 WindowLayoutTests, M1.T19 J02).",
                  line(t="title", v="Harbour town weekend plan", delayMs=400)] + tokens_of(
        "Hello! How can I help you today?", 20)
    s["stream-600w"] = ["# 600 words at 25 ms each (~15 s): stop/kill mid-stream (M1.T06 J02, J13)."]
    s["stream-600w"] += [line(t="title", v="A long harbour town story", delayMs=400)] + words(600, 25)
    s["tool-call"] = [
        "# Turn 1: a short preface and one echo call; turn 2 (after the tool result): the answer.",
        line(t="title", v="Echo tool check", delayMs=300),
        *tokens_of("Let me check that.", 20),
        line(t="toolCallDelta", id="call_1", name="echo", v="{\"text\":"),
        line(t="toolCallDelta", id="call_1", v="\"hello\"}"),
        line(t="toolCallDone", id="call_1", name="echo", args="{\"text\":\"hello\"}", delayMs=20),
        line(t="turn"),
        *tokens_of("The tool answered: hello.", 20),
    ]
    s["reasoning"] = [
        "# ~6 s of reasoning (120 × 50 ms), then the answer (M1.T15 ThinkHarderTests)."]
    s["reasoning"] += [line(t="reasoningDelta", v=" thinking", delayMs=50, repeat=120)]
    s["reasoning"] += tokens_of("After thinking it over: the answer is 42.", 20)
    s["crash-mid-stream"] = ["# 40 words, then the engine dies (helper: process exit; in-process: engine.restarted)."]
    s["crash-mid-stream"] += words(40, 25) + [line(t="crash")]
    s["slow-load"] = [
        "# Load progress 0→100% over 8 s (20 steps), first time only; then a short reply (M1.T19 QueueTests).",
        line(t="load", ms=8000, steps=20),
        line(t="title", v="Greeting while loading", delayMs=300),
        *tokens_of("Ready now. What would you like to do?", 20),
    ]
    s["s2"] = ["# S-2 shell-parity journeys 2, 3, 9 (M1.T01): one Markdown reply per turn."]
    s["s2"] += tokens_of(S2_REPLY, 15)
    s["tool-loop-runaway"] = [
        "# Calls echo with fresh arguments on every step and never answers (M1.T16 tool.loopLimit).",
        line(t="toolCallDone", id="call_{{n}}", name="echo", args="{\"text\":\"step {{n}}\"}", delayMs=30),
    ]
    s["tool-approval"] = [
        "# One write_note call (write side effect: the ApprovalCard asks), then the answer (M1.T16 J12ToolApprovalTests).",
        line(t="toolCallDone", id="call_{{n}}", name="write_note", args="{\"text\":\"buy milk\"}", delayMs=30),
        line(t="turn"),
        *tokens_of("Saved your note.", 20),
    ]
    s["long-context"] = [
        "# ~600-token replies so 6 turns cross 85% of a 4,096-token window (M1.T18 ContextTests).",
        line(t="textDelta", v=" context", delayMs=2, repeat=600),
    ]
    s["no-reasoning"] = [
        line(t="caps", reasoning=False),
        "# A model without reasoning (Think harder disabled, M1.T15).",
        *tokens_of("Here is a direct answer without thinking.", 20),
    ]
    s["mixed-3k"] = ["# ~3,000-token Markdown reply (code, table, LaTeX) at 10 ms per token (M1.T09 AT-008, NFR-U5)."]
    s["mixed-3k"] += tokens_of(mixed_3k(), 10)
    s["regen"] = [
        "# Versioned replies (M1.T10 J03EditVersionsTests): {{v}} = the n-th play of that turn, so each regenerate /",
        "# edit of the same turn gets a distinguishable reply. Markdown, so Copy has rich text to write.",
        line(t="textDelta", v="Answer v{{v}}:", delayMs=15),
        line(t="textDelta", v=" the harbour town has", delayMs=15),
        line(t="textDelta", v=" **three** piers", delayMs=15),
        line(t="textDelta", v=" and a `lighthouse`.", delayMs=15),
        line(t="turn"),
        line(t="textDelta", v="Follow-up v{{v}}:", delayMs=15),
        line(t="textDelta", v=" the ferry leaves at noon.", delayMs=15),
    ]
    # Visual QA (M10 harness issue 5): every prompt a capture leg sends gets a reply about that prompt (`when`), so
    # the blind scorers judge the product, not a canned reply to another question.
    s["vq-chat"] = [
        "# Visual QA vq-m9 legs (m9, m9-edit, m9-mac): one reply per prompt the probe sends, picked by `when`.",
        "# Titles stay the chat's temporary title (the scripted engine has one title line per script).",
    ]
    for when, reply, delay in VQ_CHAT:
        s["vq-chat"] += [line(t="textDelta", v=(p if i == 0 else " " + p), delayMs=delay, when=when)
                         for i, p in enumerate(reply.split(" "))]
    s["vq-voice"] = [
        "# Visual QA vq-m3 voice leg: the typed packing question before the voice states (S-16).",
        line(t="title", v="Spring weekend in Lisbon", delayMs=400),
        *tokens_of(VQ_VOICE_REPLY, 15),
    ]
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/scripts")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    bad = 0
    for name, lines in scripts().items():
        text = "\n".join(lines) + "\n"
        p = out / f"{name}.jsonl"
        if a.check:
            if not p.exists() or p.read_text(encoding="utf-8") != text:
                print(f"stale: {p}")
                bad += 1
        else:
            out.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
    print(f"gen-scripts: {'FAIL ' + str(bad) if bad else 'ok'} ({len(scripts())} scripts, {out})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
