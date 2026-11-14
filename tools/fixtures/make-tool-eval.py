#!/usr/bin/env python3
"""M1.T13 AT-231 tool-calling eval set: antichat-tools-200.jsonl (+ bfcl-subset-100.jsonl, SOURCES fragment).

  bfcl-subset-100  ShishirPatil/gorilla@6ea5797 (Apache-2.0) BFCL v4 data, 40 simple_python + 30 multiple +
                   30 parallel, picked with random.Random(20261030); the input files' sha256 are checked.
                   BFCL dialect fixes for OpenAI-style tools (as BFCL does for its OpenAI handler): `.` in function
                   names → `_`, `dict` → `object`, `float` → `number`, `tuple` → `array`, `any` → untyped.
  agentic-30       fixtures/prompts/agentic-30.jsonl (M0.T09, CC0), unchanged.
  antichat-70      70 new prompts authored here (CC0), 10 per AntiChat tool: web_search, create_image, create_file,
                   memory_write, mcp_call, get_time, run_python; all eight tools offered on every row.
Row: {id, source, prompt, messages, tools, expected_tool, expected_args_schema, expected_args_contains?}
  expected_tool = tool name (single), or a list of names (BFCL parallel: every listed call, any order).

Usage: python3 -I tools/fixtures/make-tool-eval.py --bfcl <dir with BFCL_v4_*.json + possible_answer/>
        --agentic fixtures/prompts/agentic-30.jsonl --out <dir>
Stdlib only, deterministic.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

GORILLA = "ShishirPatil/gorilla@6ea57973c7a6097fd7c5915698c54c17c5b1b6c8"
BFCL_DIR = "berkeley-function-call-leaderboard/bfcl_eval/data"
SEED = 20261030
# sha256 of the BFCL inputs at 6ea5797 (raw.githubusercontent.com, fetched 2026-10-30).
PINNED = {
    "BFCL_v4_simple_python.json": "82dd63ba502eb2520c6b5d1d9a5c4b590e03ff261565175561f6228a367d1991",
    "BFCL_v4_multiple.json": "aef168155ebd74b7ac2401198b201343bc7d16d7a3d7e0d4e6d8ee82c6969b2a",
    "BFCL_v4_parallel.json": "19f51a82eff42e5d62541aa500115a056eb78f437c2ba1f10415fd7c8e5dda84",
}
SYSTEM = ("You are a helpful assistant in a Mac chat app. Today is Friday 2026-10-30. Use a tool when it is the best "
          "way to answer; otherwise answer directly.")  # same system line as agentic-30


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def fix_schema(v):
    if isinstance(v, dict):
        d = dict(v)
        t = d.get("type")
        m = {"dict": "object", "float": "number", "tuple": "array", "list": "array", "int": "integer", "bool": "boolean",
             "str": "string", "String": "string", "Boolean": "boolean", "any": None, "Any": None}
        if isinstance(t, str) and t in m:
            if m[t] is None:
                d.pop("type")
            else:
                d["type"] = m[t]
        for k in ("properties",):
            if isinstance(d.get(k), dict):
                d[k] = {kk: fix_schema(vv) for kk, vv in d[k].items()}
        if "items" in d:
            d["items"] = fix_schema(d["items"])
        if isinstance(d.get("required"), list) and isinstance(d.get("properties"), dict):
            d["required"] = [r for r in d["required"] if r in d["properties"]]
        return d
    return v


def oai_name(n: str) -> str:
    return n.replace(".", "_")


def bfcl_rows(bfcl: Path) -> list[dict]:
    rows = []
    rng = random.Random(SEED)
    for fname, n, cat in (("BFCL_v4_simple_python.json", 40, "simple"), ("BFCL_v4_multiple.json", 30, "multiple"),
                          ("BFCL_v4_parallel.json", 30, "parallel")):
        q = [json.loads(l) for l in (bfcl / fname).read_text(encoding="utf-8").splitlines() if l.strip()]
        a = {r["id"]: r for r in (json.loads(l) for l in (bfcl / "possible_answer" / fname).read_text(encoding="utf-8").splitlines() if l.strip())}
        for item in sorted(rng.sample(q, n), key=lambda r: int(r["id"].rsplit("_", 1)[1])):
            tools = [{"type": "function", "function": {"name": oai_name(f["name"]), "description": f.get("description", ""),
                                                       "parameters": fix_schema(f["parameters"])}} for f in item["function"]]
            gt = a[item["id"]]["ground_truth"]
            names = [oai_name(next(iter(g))) for g in gt]
            schema = {t["function"]["name"]: t["function"]["parameters"] for t in tools}
            user = item["question"][0]
            rows.append({
                "id": f"bfcl-{item['id']}", "category": f"bfcl_{cat}",
                "source": {"repo": GORILLA, "file": f"{BFCL_DIR}/{fname}", "id": item["id"], "sha256": sha256(bfcl / fname)},
                "prompt": user[-1]["content"], "messages": [{"role": "system", "content": SYSTEM}] + user,
                "tools": tools, "expected_tool": names if cat == "parallel" else names[0],
                "expected_args_schema": schema[names[0]], "ground_truth": gt,
            })
    return rows


def agentic_rows(path: Path) -> list[dict]:
    rows = []
    for l in path.read_text(encoding="utf-8").splitlines():
        if not l.strip():
            continue
        r = json.loads(l)
        name = r["expected"]["name"]
        schema = next(t["function"]["parameters"] for t in r["tools"] if t["function"]["name"] == name)
        rows.append({"id": r["id"], "category": f"agentic_{r['category']}",
                     "source": {"file": "fixtures/prompts/agentic-30.jsonl", "id": r["id"], "sha256": sha256(path)},
                     "prompt": r["messages"][-1]["content"], "messages": r["messages"], "tools": r["tools"],
                     "expected_tool": name, "expected_args_schema": schema,
                     "expected_args_contains": r["expected"].get("args_contains", {})})
    return rows


S = {"type": "string"}


def tool(name, desc, props, req):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": req}}}


ANTICHAT_TOOLS = [
    tool("web_search", "Search the web for current information (news, prices, schedules, recent facts).",
         {"query": S, "recency": {"type": "string", "enum": ["day", "week", "month", "any"]}}, ["query"]),
    tool("create_image", "Generate an image from a text prompt.",
         {"prompt": S, "aspect_ratio": {"type": "string", "enum": ["1:1", "16:9", "9:16", "4:3"]},
          "count": {"type": "integer", "minimum": 1, "maximum": 4}}, ["prompt"]),
    tool("create_file", "Create a downloadable file (spreadsheet, document, slides, csv, markdown).",
         {"filename": S, "format": {"type": "string", "enum": ["xlsx", "docx", "pptx", "csv", "md"]}, "title": S, "body": S},
         ["filename", "format"]),
    tool("memory_write", "Save a durable fact about the user for future chats.",
         {"fact": S, "category": {"type": "string", "enum": ["preference", "personal", "work", "other"]}}, ["fact", "category"]),
    tool("memory_search", "Look up facts previously saved about the user.", {"query": S}, ["query"]),
    tool("mcp_call", "Call a tool of a connected MCP server (connectors: calendar, github, notes, mail).",
         {"server": {"type": "string", "enum": ["calendar", "github", "notes", "mail"]}, "tool": S,
          "arguments": {"type": "object"}}, ["server", "tool", "arguments"]),
    tool("get_time", "Get the current local date and time, optionally in another IANA time zone.",
         {"timezone": {"type": "string", "description": "IANA zone, e.g. Europe/Lisbon"}}, []),
    tool("run_python", "Run Python 3 code in a local sandbox and return stdout (for maths, data and file analysis).",
         {"code": S}, ["code"]),
]

NEW = {
    "web_search": [("What's the latest news about the Mars Sample Return mission?", {"query": "mars"}),
                   ("Find today's exchange rate from euros to Japanese yen.", {"query": "yen|eur"}),
                   ("Who won last night's Champions League matches?", {"query": "champions"}),
                   ("Search for the opening hours of the Rijksmuseum this week.", {"query": "rijksmuseum"}),
                   ("What are the reviews saying about the newest iPhone?", {"query": "iphone"}),
                   ("Look up the current train strike situation in France.", {"query": "strike|train"}),
                   ("Is the Golden Gate Bridge closed today?", {"query": "golden gate"}),
                   ("Find recent studies on intermittent fasting published this month.", {"query": "fasting"}),
                   ("What's the price of Bitcoin right now?", {"query": "bitcoin"}),
                   ("Search the web for ticket prices for the next Coldplay tour.", {"query": "coldplay"})],
    "create_image": [("Create an image of a lighthouse at sunset in watercolor style.", {"prompt": "lighthouse"}),
                     ("Draw a cute cat astronaut floating in space.", {"prompt": "cat"}),
                     ("Generate a 16:9 banner of a mountain lake at dawn.", {"prompt": "lake|mountain", "aspect_ratio": "16:9"}),
                     ("Make three images of a vintage bicycle against a brick wall.", {"prompt": "bicycle"}),
                     ("Paint a picture of a busy Tokyo street in the rain.", {"prompt": "tokyo|street"}),
                     ("I want a square logo sketch of a friendly owl.", {"prompt": "owl"}),
                     ("Create a 9:16 poster of a jazz band on stage.", {"prompt": "jazz", "aspect_ratio": "9:16"}),
                     ("Generate an illustration of a dragon reading a book.", {"prompt": "dragon"}),
                     ("Make an image of a bowl of ramen, photo style.", {"prompt": "ramen"}),
                     ("Draw a 4:3 picture of a cozy cabin in the snowy woods.", {"prompt": "cabin", "aspect_ratio": "4:3"})],
    "create_file": [("Make a CSV of the planets with their order from the sun.", {"format": "csv"}),
                    ("Create a Word document with a one-page cover letter template.", {"format": "docx"}),
                    ("Build an Excel sheet for tracking my weekly running distances.", {"format": "xlsx"}),
                    ("Make a slide deck outline (pptx) about recycling for a school talk.", {"format": "pptx"}),
                    ("Save these notes as a markdown file: buy milk, call mum, book dentist.", {"format": "md"}),
                    ("Create a spreadsheet of my monthly bills: rent 900, power 60, internet 35.", {"format": "xlsx|csv"}),
                    ("Write a docx file with a simple meeting agenda for Monday.", {"format": "docx"}),
                    ("Export a CSV with three columns: name, email, phone (empty rows).", {"format": "csv"}),
                    ("Create a markdown file with a packing checklist for a beach trip.", {"format": "md"}),
                    ("Make a pptx with three slides introducing our book club.", {"format": "pptx"})],
    "memory_write": [("Remember that my favourite colour is green.", {"fact": "green"}),
                     ("Please remember I'm allergic to peanuts.", {"fact": "peanut"}),
                     ("Keep in mind that I work as a teacher.", {"fact": "teacher"}),
                     ("Remember my son's birthday is on 12 March.", {"fact": "march"}),
                     ("Note for later: I prefer short answers.", {"fact": "short"}),
                     ("Remember that I live in Porto.", {"fact": "porto"}),
                     ("Save this about me: I'm learning Japanese.", {"fact": "japanese"}),
                     ("Remember that my dog is called Biscuit.", {"fact": "biscuit"}),
                     ("Please remember I don't drink coffee.", {"fact": "coffee"}),
                     ("Remember I use a MacBook Air for work.", {"fact": "macbook"})],
    "mcp_call": [("Add 'Lunch with Ana' to my calendar tomorrow at 13:00.", {"server": "calendar"}),
                 ("List my open GitHub issues in the repo acme/website.", {"server": "github"}),
                 ("Create a note titled 'Gift ideas' in my notes.", {"server": "notes"}),
                 ("Send an email to bob@example.com saying I'll be late.", {"server": "mail"}),
                 ("What's on my calendar for next Monday?", {"server": "calendar"}),
                 ("Open a GitHub issue in acme/app titled 'Login button broken'.", {"server": "github"}),
                 ("Search my notes for 'wifi password'.", {"server": "notes"}),
                 ("Move my 3pm calendar meeting on Friday to 4pm.", {"server": "calendar"}),
                 ("Check my mail for messages from the landlord.", {"server": "mail"}),
                 ("Close GitHub issue 42 in acme/website.", {"server": "github"})],
    "get_time": [("What time is it right now?", {}),
                 ("What's the time in Tokyo?", {"timezone": "tokyo"}),
                 ("What time is it in Mumbai right now?", {"timezone": "kolkata|mumbai|calcutta"}),
                 ("What time is it in New York at the moment?", {"timezone": "new_york|new york"}),
                 ("Is it morning or evening in Sydney right now?", {"timezone": "sydney"}),
                 ("Tell me the current time in Lisbon.", {"timezone": "lisbon"}),
                 ("What's the current time in Seoul?", {"timezone": "seoul"}),
                 ("What is the current time in London?", {"timezone": "london"}),
                 ("Current time in Los Angeles, please.", {"timezone": "los_angeles|los angeles"}),
                 ("What's the local time in Berlin now?", {"timezone": "berlin"})],
    "run_python": [("Use Python to compute the 30th Fibonacci number.", {"code": "fib|def|30"}),
                   ("Run code to find all primes below 50.", {"code": "prime|range"}),
                   ("Calculate the standard deviation of 4, 8, 15, 16, 23, 42 with Python.", {"code": "4"}),
                   ("Use Python to convert 98.6 Fahrenheit to Celsius.", {"code": "98"}),
                   ("Run a script that counts the words in 'the quick brown fox jumps'.", {"code": "split|len"}),
                   ("Use Python to compute compound interest on 1000 at 5% for 10 years.", {"code": "1000"}),
                   ("Execute Python to sort ['pear', 'apple', 'fig'] alphabetically.", {"code": "sort"}),
                   ("Compute 2 to the power of 64 using Python.", {"code": "2"}),
                   ("Use Python to generate a random password of 12 characters.", {"code": "random|secrets"}),
                   ("Run Python to find the day of the week for 2000-01-01.", {"code": "date|2000"})],
}


def antichat_rows() -> list[dict]:
    rows = []
    for name, items in NEW.items():
        for i, (p, contains) in enumerate(items, 1):
            schema = next(t["function"]["parameters"] for t in ANTICHAT_TOOLS if t["function"]["name"] == name)
            rows.append({"id": f"ac-{name}-{i:02d}", "category": f"antichat_{name}",
                         "source": {"file": "tools/fixtures/make-tool-eval.py", "authored": "AntiChat M1.T13, CC0"},
                         "prompt": p, "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": p}],
                         "tools": ANTICHAT_TOOLS, "expected_tool": name, "expected_args_schema": schema,
                         "expected_args_contains": contains})
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bfcl", required=True, type=Path)
    ap.add_argument("--agentic", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    for f, want in PINNED.items():
        got = sha256(a.bfcl / f)
        if got != want:
            sys.exit(f"{f}: sha256 {got} != pinned {want}")
    b, ag, ac = bfcl_rows(a.bfcl), agentic_rows(a.agentic), antichat_rows()
    assert (len(b), len(ag), len(ac)) == (100, 30, 70), (len(b), len(ag), len(ac))
    a.out.mkdir(parents=True, exist_ok=True)
    for name, rows in (("bfcl-subset-100", b), ("antichat-tools-200", b + ag + ac)):
        with open(a.out / f"{name}.jsonl", "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")
        print(f"{name}.jsonl: {len(rows)} rows")


if __name__ == "__main__":
    main()
