#!/usr/bin/env python3
"""M7.T03 step 11 (AT-250 c2, R-250 AC2): `prompts/citation-qa-100.jsonl` + recorded search and page snapshots.

  make-citation-qa.py [--fixtures DIR]              write prompts/citation-qa-100.jsonl (seed 11)
  make-citation-qa.py --capture [--fixtures DIR]    + record web/citation-qa-100/<qid>/ through the app's pipeline

100 questions that need current or factual web information, built from fixed templates x topics with
random.Random(11) (public organisations, software, places, science; no personal data). Each row is
`{id, category, question, query}`; `query` is the one search the snapshot was recorded for.

`--capture` needs the network (Q-007). It runs `antichat-bench citations --capture` (the app's own SearchBroker over
the gate with the five keyless engines, then PageFetcher + SSRF guard for the top 6 hits, the T3/T4 page count so
every tier replays offline). Bot checks (HTTP 429, captcha, proof-of-work pages) are saved as returned and an engine
is skipped after 3 blocked answers in a row: the capture never retries around a challenge. Run with `python3 -I`.
"""
from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

TEMPLATES = [
    ("software", "What is the latest stable version of {t}?", "{t} latest stable version"),
    ("software", "When was the most recent release of {t} published?", "{t} release notes"),
    ("org", "Who is the current chief executive of {t}?", "{t} CEO"),
    ("org", "Where is the headquarters of {t} located?", "{t} headquarters"),
    ("place", "What is the population of {t}?", "{t} population"),
    ("place", "What is the official language of {t}?", "{t} official language"),
    ("science", "What is the main use of {t}?", "{t} uses"),
    ("science", "Who discovered {t}?", "{t} discovery"),
    ("event", "Where will the next {t} be held?", "next {t} host"),
    ("event", "Who won the most recent {t}?", "{t} latest winner"),
]
TOPICS = {
    "software": ["Python", "Node.js", "PostgreSQL", "Rust", "Go programming language", "LibreOffice", "Firefox",
                 "Blender", "Kubernetes", "SQLite", "Linux kernel", "GIMP", "VLC media player", "Git", "Django"],
    "org": ["the Wikimedia Foundation", "Mozilla", "the Linux Foundation", "the World Health Organization", "CERN",
            "the European Space Agency", "UNESCO", "the Red Cross", "Airbus", "Nokia", "Spotify", "Lego",
            "IKEA", "Volvo Cars", "Siemens"],
    "place": ["Iceland", "Uruguay", "New Zealand", "Lisbon", "Nairobi", "Montreal", "Singapore", "Chile",
              "Finland", "Vienna", "Ghana", "Kyoto", "Bolivia", "Tasmania", "Estonia"],
    "science": ["graphene", "CRISPR", "penicillin", "the transistor", "radar", "insulin", "lithium-ion batteries",
                "the Higgs boson", "X-rays", "nylon", "superconductors", "carbon dating", "the laser",
                "mRNA vaccines", "perovskite solar cells"],
    "event": ["FIFA World Cup", "Summer Olympic Games", "Eurovision Song Contest", "Tour de France",
              "Nobel Prize in Physics", "UN Climate Change Conference", "Wimbledon men's singles",
              "Rugby World Cup", "Chess World Championship", "Winter Olympic Games"],
}


def build() -> list[dict]:
    rng = random.Random(11)
    pool = [(cat, q.format(t=t), s.format(t=t)) for cat, q, s in TEMPLATES for t in TOPICS[cat]]
    rng.shuffle(pool)
    seen, rows = set(), []
    for cat, q, s in pool:
        if q in seen:
            continue
        seen.add(q)
        rows.append({"id": f"c{len(rows) + 1:03d}", "category": cat, "question": q, "query": s})
        if len(rows) == 100:
            break
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    ap.add_argument("--capture", action="store_true")
    ap.add_argument("--bench", default=str(ROOT / ".build/debug/antichat-bench"))
    a = ap.parse_args()
    fx = Path(a.fixtures)
    out = fx / "prompts" / "citation-qa-100.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in build()), encoding="utf-8")
    print(f"wrote {out}")
    if a.capture:
        return subprocess.call([a.bench, "citations", "--capture", "--fixture", str(out),
                                "--root", str(fx / "web" / "citation-qa-100")])
    return 0


if __name__ == "__main__":
    sys.exit(main())
