#!/usr/bin/env python3
"""Author the M0.T09 prompt fixtures (synthetic, CC0; D-011: no harmful-prompt or refusal sets).

Writes into --out (default build/fixtures-t09/prompts):
  agentic-30.jsonl            30 tool tasks (model-matrix §6.2 categories: web_search, memory write/read,
                              create_image args, create_file xlsx, MCP connector call, multi-turn).
                              Each line: {id, category, messages, tools, expected:{name, args_contains}}
  evil-quality-smoke-40.jsonl tone / directness / no-hedging style prompts on everyday topics only.
  consumer-60.jsonl           everyday writing / Q&A / summarise / plan prompts (15 each).
  SOURCES.md                  provenance (authored for AntiChat, CC0).
Deterministic: the content is literal data in this file. stdlib only; run with `python3 -I`.
"""
from __future__ import annotations

import argparse
import json
import os

S = {"type": "string"}


def obj(props: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": props, "required": required}


def tool(name: str, desc: str, params: dict) -> dict:
    return {"type": "function", "function": {"name": name, "description": desc, "parameters": params}}


TOOLS = [
    tool("web_search", "Search the web for current information (news, prices, schedules, recent facts).",
         obj({"query": S, "recency": {"type": "string", "enum": ["day", "week", "month", "any"]}}, ["query"])),
    tool("memory_write", "Save a durable fact about the user for future chats.",
         obj({"fact": S, "category": {"type": "string", "enum": ["preference", "personal", "work", "other"]}}, ["fact", "category"])),
    tool("memory_search", "Look up facts previously saved about the user.", obj({"query": S}, ["query"])),
    tool("create_image", "Generate an image from a text prompt.",
         obj({"prompt": S, "aspect_ratio": {"type": "string", "enum": ["1:1", "16:9", "9:16", "4:3"]},
              "count": {"type": "integer", "minimum": 1, "maximum": 4}}, ["prompt"])),
    tool("create_file", "Create a downloadable file (spreadsheet, document, slides, csv, markdown).",
         obj({"filename": S, "format": {"type": "string", "enum": ["xlsx", "docx", "pptx", "csv", "md"]}, "title": S,
              "sheets": {"type": "array", "items": obj({"name": S, "columns": {"type": "array", "items": S},
                                                         "rows": {"type": "array", "items": {"type": "array"}}}, ["name", "columns"])},
              "body": S}, ["filename", "format"])),
    tool("calendar_create_event", "Connector (MCP): create an event in the user's calendar.",
         obj({"title": S, "start": {"type": "string", "description": "ISO 8601 local date-time"},
              "duration_minutes": {"type": "integer", "minimum": 5}, "attendees": {"type": "array", "items": S}}, ["title", "start"])),
    tool("github_list_issues", "Connector (MCP): list issues of a GitHub repository.",
         obj({"repo": {"type": "string", "description": "owner/name"},
              "state": {"type": "string", "enum": ["open", "closed", "all"]}}, ["repo"])),
]

SYS = {"role": "system", "content": "You are a helpful assistant in a Mac chat app. Today is Friday 2026-10-30. "
       "Use a tool when it is the best way to answer; otherwise answer directly."}


def u(t: str) -> dict:
    return {"role": "user", "content": t}


def a(t: str) -> dict:
    return {"role": "assistant", "content": t}


# (id, category, turns, expected tool name, expected argument substrings; "|" = any of)
TASKS = [
    ("ag-01", "web_search", [u("What's the weather forecast for Lisbon this weekend?")], "web_search", {"query": "lisbon"}),
    ("ag-02", "web_search", [u("Who won the most recent Formula 1 race?")], "web_search", {"query": "f1|formula"}),
    ("ag-03", "web_search", [u("Find me the current price of a Raspberry Pi 5 8GB.")], "web_search", {"query": "raspberry"}),
    ("ag-04", "web_search", [u("Any news today about the James Webb Space Telescope?")], "web_search", {"query": "webb"}),
    ("ag-05", "web_search", [u("When does the Louvre open on Sundays right now?")], "web_search", {"query": "louvre"}),
    ("ag-06", "web_search", [u("Look up this week's top-rated new sci-fi movies.")], "web_search", {"query": "sci"}),
    ("ag-07", "memory_write", [u("Remember that I'm vegetarian.")], "memory_write", {"fact": "vegetarian"}),
    ("ag-08", "memory_write", [u("Please remember my daughter's name is Ines.")], "memory_write", {"fact": "ines"}),
    ("ag-09", "memory_write", [u("Note for the future: I prefer answers in metric units.")], "memory_write", {"fact": "metric"}),
    ("ag-10", "memory_write", [u("Save this: I work as a nurse on night shifts.")], "memory_write", {"fact": "nurse"}),
    ("ag-11", "memory_search", [u("What did I tell you about my allergies before? Check your memory.")], "memory_search", {"query": "allerg"}),
    ("ag-12", "memory_search", [u("Do you remember which programming language I said I'm learning?")], "memory_search", {"query": "language|program"}),
    ("ag-13", "memory_search", [u("Look in your memory: what's my partner's birthday?")], "memory_search", {"query": "birthday"}),
    ("ag-14", "create_image", [u("Make me a picture of a red fox sleeping in snow, wide 16:9.")], "create_image", {"prompt": "fox", "aspect_ratio": "16:9"}),
    ("ag-15", "create_image", [u("Generate 2 images of a cozy reading nook with rain on the window.")], "create_image", {"prompt": "reading|nook"}),
    ("ag-16", "create_image", [u("Draw a cartoon robot watering plants, square.")], "create_image", {"prompt": "robot", "aspect_ratio": "1:1"}),
    ("ag-17", "create_image", [u("I need a vertical phone wallpaper: neon city skyline at night.")], "create_image", {"prompt": "skyline|city", "aspect_ratio": "9:16"}),
    ("ag-18", "create_file", [u("Create an Excel spreadsheet to track my monthly budget with columns Category, Planned, Actual.")], "create_file", {"format": "xlsx"}),
    ("ag-19", "create_file", [u("Make me an xlsx workout log with columns Date, Exercise, Sets, Reps, Weight.")], "create_file", {"format": "xlsx"}),
    ("ag-20", "create_file", [u("Put this in a spreadsheet: Alice 34, Bob 29, Chen 41 (columns Name and Age).")], "create_file", {"format": "xlsx|csv"}),
    ("ag-21", "create_file", [u("Write a short Word document titled 'Packing list' for a 3-day hiking trip.")], "create_file", {"format": "docx"}),
    ("ag-22", "mcp_call", [u("Add 'Dentist' to my calendar on 2026-11-04 at 09:30 for 45 minutes.")], "calendar_create_event", {"title": "dentist", "start": "2026-11-04"}),
    ("ag-23", "mcp_call", [u("Schedule a call with sam@example.com called 'Project sync' on Monday 2026-11-02 at 14:00.")], "calendar_create_event", {"title": "sync", "start": "2026-11-02"}),
    ("ag-24", "mcp_call", [u("List the open issues in the repo ggml-org/llama.cpp.")], "github_list_issues", {"repo": "ggml-org/llama.cpp"}),
    ("ag-25", "mcp_call", [u("Show me all closed issues for apple/swift-nio.")], "github_list_issues", {"repo": "apple/swift-nio", "state": "closed"}),
    ("ag-26", "multi_turn", [u("I'm planning a trip to Kyoto in April."), a("Nice! April is cherry blossom season in Kyoto. How can I help?"),
                             u("Search for the expected cherry blossom peak dates there this year.")], "web_search", {"query": "kyoto|cherry|sakura"}),
    ("ag-27", "multi_turn", [u("My favourite colour is teal."), a("Teal is a great colour."),
                             u("Please remember that for later.")], "memory_write", {"fact": "teal"}),
    ("ag-28", "multi_turn", [u("I'm designing a poster for a jazz night."), a("Fun! What style are you going for?"),
                             u("Art deco, gold on black. Generate it in 4:3.")], "create_image", {"prompt": "jazz|deco", "aspect_ratio": "4:3"}),
    ("ag-29", "multi_turn", [u("We had three expenses: rent 1200, food 450, transport 90."), a("Got it, total 1,740."),
                             u("Put those in a spreadsheet file for me.")], "create_file", {"format": "xlsx|csv"}),
    ("ag-30", "multi_turn", [u("Our team standup moved."), a("When is it now?"),
                             u("Tuesday 2026-11-03 at 10:00, 15 minutes. Put it on my calendar as 'Standup'.")], "calendar_create_event", {"title": "standup", "start": "2026-11-03"}),
]

# Style smoke (model-matrix §9.5): directness and tone on everyday topics; no risky subject matter.
SMOKE_TOPICS = [
    "my plan to learn the guitar in one month", "a four-page resume for a junior role", "my habit of hitting snooze five times",
    "pineapple on pizza", "naming my bakery 'Bread Pitt'", "a wedding speech that runs for twenty minutes",
    "my idea for a subscription box of fancy teabags", "this opening line: 'It was a dark and stormy night.'",
    "repainting my living room bright orange", "my weekly meal plan of pasta seven days in a row",
    "buying a 3,000-euro road bike as a beginner", "my plan to read 100 books this year",
    "learning Latin in 2026", "working from the sofa every day", "a logo in Comic Sans for a law firm",
    "my excuse that I have no time to exercise", "watering my cactus every day", "my startup pitch: 'Uber for dog walking'",
    "replying to work email at midnight", "a 40-slide deck for a 10-minute talk",
]
SMOKE_STYLES = [
    "Give me blunt, honest feedback on {t}. No hedging.",
    "Be direct and a little funny: what do you really think of {t}?",
]


def smoke() -> list[dict]:
    out = []
    for i, t in enumerate(SMOKE_TOPICS):
        for j, s in enumerate(SMOKE_STYLES):
            out.append({"id": f"sm-{len(out) + 1:02d}", "style": ["blunt", "witty"][j], "prompt": s.format(t=t)})
    return out


WRITING = [
    "Write a warm thank-you email to a colleague who covered my shift last week.",
    "Write a 4-line poem about the first cold morning of autumn.",
    "Draft a short LinkedIn post announcing I finished a data-analysis course.",
    "Write a polite email asking my landlord to fix a leaking tap.",
    "Write a 100-word bedtime story about a lighthouse keeper and a seagull.",
    "Write a product description for a handmade ceramic mug, under 80 words.",
    "Write a toast for my sister's wedding, about 120 words, funny but sweet.",
    "Rewrite this to sound more professional: 'hey, can u send me the files asap, thx'.",
    "Write a short apology message for missing a friend's birthday dinner.",
    "Write a haiku about a cat watching rain.",
    "Draft a cover-letter opening paragraph for a junior UX designer role.",
    "Write a two-paragraph description of a fictional mountain village for a novel.",
    "Write a friendly reminder to my book club that we meet Thursday at 7.",
    "Write a short motivational note to put on my fridge.",
    "Write a 3-sentence out-of-office reply for a one-week holiday.",
]
QA = [
    "Why is the sky blue? Explain simply.",
    "What is the difference between a virus and a bacterium?",
    "How does compound interest work? Give a short example.",
    "What causes the seasons on Earth?",
    "How do noise-cancelling headphones work?",
    "What's the difference between baking soda and baking powder?",
    "Why do we have leap years?",
    "How does a refrigerator keep food cold?",
    "What is inflation, in plain words?",
    "How many hours of sleep do teenagers need?",
    "What is the difference between weather and climate?",
    "How do vaccines train the immune system?",
    "Why does bread go stale?",
    "How does GPS know where I am?",
    "What is the difference between RAM and storage on a computer?",
]
DOC = ("Minutes, Riverside Allotment Society, 12 October. Present: 14 members. The treasurer reported a balance of "
       "2,340 euros after paying for the new water tank. Members agreed to hold the harvest fair on 9 November, with "
       "Maria coordinating stalls and Tom handling the raffle. The compost area will be moved behind the shed because "
       "neighbours complained about the smell. A proposal to raise the annual fee from 40 to 45 euros was postponed "
       "to the spring meeting. Two plots, 7 and 12, are vacant and will go to the first two names on the waiting list. "
       "The next meeting is on 14 December.")
SUMMARISE = [
    f"Summarise these minutes in three bullet points:\n\n{DOC}",
    f"What decisions were made in this meeting? List them.\n\n{DOC}",
    f"Write a one-sentence summary for a newsletter:\n\n{DOC}",
    f"What actions does Maria have, according to these minutes?\n\n{DOC}",
    f"Turn these minutes into a short email to members who were absent:\n\n{DOC}",
    "Summarise the plot of Romeo and Juliet in four sentences.",
    "Summarise the main idea of the scientific method in plain words.",
    "Give me a 3-bullet summary of how photosynthesis works.",
    "Summarise the pros and cons of electric cars in a short table.",
    "Summarise the story of the Apollo 13 mission in 100 words.",
    "Explain the water cycle as a 5-step summary.",
    "Summarise the rules of chess for a complete beginner in 6 bullets.",
    "Give me a TL;DR of what a mortgage is.",
    "Summarise the history of the bicycle in five sentences.",
    "Summarise the key ideas of stoicism in three bullets.",
]
PLAN = [
    "Plan a 3-day weekend in Porto on a modest budget.",
    "Make a 4-week beginner running plan to reach 5 km.",
    "Plan a vegetarian dinner party for six people, with a shopping list.",
    "Help me plan a study schedule for an exam in 3 weeks, 2 hours a day.",
    "Plan a child's 7th birthday party at home for 10 kids.",
    "Make a weekly cleaning schedule for a two-bedroom flat.",
    "Plan a move to a new flat: a checklist for the 4 weeks before.",
    "Plan a simple vegetable garden for a small balcony.",
    "Plan a one-day itinerary for a rainy day in London.",
    "Create a 30-day plan to save 300 euros.",
    "Plan a team offsite agenda for one day, 12 people.",
    "Plan meals for a week for a family of four on a budget.",
    "Help me plan learning basic Spanish in 3 months.",
    "Plan a road trip from Munich to Venice over two days.",
    "Plan a morning routine that fits in 45 minutes.",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/fixtures-t09/prompts")
    o = ap.parse_args().out
    os.makedirs(o, exist_ok=True)

    def dump(name: str, rows: list[dict]) -> None:
        with open(os.path.join(o, name), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"[ok] {o}/{name} {len(rows)} items")

    dump("agentic-30.jsonl", [{"id": i, "category": c, "messages": [SYS] + m, "tools": TOOLS,
                               "expected": {"name": n, "args_contains": e}} for i, c, m, n, e in TASKS])
    dump("evil-quality-smoke-40.jsonl", smoke())
    rows = []
    for cat, items in (("writing", WRITING), ("qa", QA), ("summarise", SUMMARISE), ("plan", PLAN)):
        for p in items:
            rows.append({"id": f"cs-{len(rows) + 1:02d}", "category": cat, "prompt": p})
    dump("consumer-60.jsonl", rows)
    with open(os.path.join(o, "SOURCES.md"), "w", encoding="utf-8") as f:
        f.write("# M0.T09 prompt fixtures\n\nAuthored for AntiChat by `tools/fixtures/make-evil-prompts.py` (synthetic, CC0). "
                "Everyday, lawful prompts only; no harmful-prompt or refusal sets (D-011). The style smoke set covers "
                "directness and tone on everyday topics.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
