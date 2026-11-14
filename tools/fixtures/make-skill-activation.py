#!/usr/bin/env python3
"""Skills activation + script-policy fixtures (M7.T13; R-262, R-263, R-265; AT-262, AT-263, AT-265). Stdlib only,
run with `python3 -I tools/fixtures/make-skill-activation.py` (writes into $ANTICHAT_FIXTURES or ./fixtures).

Writes
  skills/activation-20/<name>/SKILL.md   the 5 starter skills (copied from Packages/Tools/.../StarterSkills) + 15
                                         synthetic, clearly distinct instruction-only skills (CC0, written for AntiChat)
  prompts/skills-activation-100.jsonl    100 prompts {id, prompt, gold}: 80 with a gold skill (4 per skill, worded
                                         without the skill's name), 20 with gold null (no skill fits); order shuffled
                                         with random.Random(13)
  skills/with-script/hello-script/       a skill with scripts/hello.sh and scripts/hello.py (AT-265)

Rules: no real personal data, no sexual content of any kind; the prompts are ordinary requests a user might type.
"""
from __future__ import annotations

import json
import os
import random
import shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIX = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
STARTERS = os.path.join(ROOT, "Packages/Tools/Sources/AntiChatTools/Resources/StarterSkills")
STARTER_NAMES = ["meeting-notes", "email-polish", "study-flashcards", "trip-planner", "recipe-scaler"]

# name → (description, body). Each body is short, instruction-only (no scripts, no network).
SYNTHETIC: dict[str, tuple[str, str]] = {
    "commit-message": (
        "Writes a git commit message from a diff or a list of code changes. Use when the user wants text for a commit, a version-control message or a changelog line for code they changed.",
        "# Commit message\n\n1. Read the diff or the change list.\n2. Subject: imperative mood, at most 50 characters, no period.\n3. Blank line, then a body wrapped at 72 characters: what changed and why.\n4. Mention breaking changes on a line starting with `BREAKING:`.\n",
    ),
    "sql-helper": (
        "Writes, explains or fixes SQL queries for described tables. Use when the user asks how to query, join, group or deduplicate data in a database, or why a query fails.",
        "# SQL helper\n\n1. Restate the tables and columns you assume.\n2. Write the query in a ```sql block, one clause per line.\n3. Explain each clause in one sentence.\n4. Point out indexes that would help.\n",
    ),
    "resume-tailor": (
        "Tailors a CV or resume to a job posting. Use when the user wants their work history, bullets or profile reworded to fit a specific role.",
        "# Resume tailor\n\n1. List the posting's top 5 requirements.\n2. Map each to evidence in the resume.\n3. Rewrite bullets as action + result + number.\n4. Flag gaps the user should address honestly.\n",
    ),
    "workout-planner": (
        "Builds a weekly exercise or training plan. Use when the user wants a workout routine, a running programme or a mobility schedule for a goal, time budget and equipment.",
        "# Workout planner\n\n1. Ask for or assume goal, days per week, equipment, level.\n2. Give a table: day, session, exercises, sets x reps or duration.\n3. Include warm-up and rest days.\n4. Add a progression rule for the next weeks.\n",
    ),
    "budget-planner": (
        "Organises personal monthly finances. Use when the user wants income and expenses categorised, a budget per category, or ideas to save money each month.",
        "# Budget planner\n\n1. Collect income and expenses.\n2. Group them into categories (housing, food, transport, fun, savings).\n3. Show a table with amount and share of income.\n4. Suggest three concrete savings.\n",
    ),
    "poem-writer": (
        "Writes poems in a requested form. Use when the user asks for a haiku, sonnet, limerick or free verse on a theme or for an occasion.",
        "# Poem writer\n\n1. Confirm form, theme and tone.\n2. Follow the form's rules (haiku 5-7-5, sonnet 14 lines, limerick AABBA).\n3. Give a title.\n4. Offer one alternative line for the weakest spot.\n",
    ),
    "code-review": (
        "Reviews source code for bugs, edge cases, readability and performance. Use when the user pastes code in a general programming language and asks what is wrong or whether it is safe to merge.",
        "# Code review\n\n1. Summarise what the code does.\n2. List issues by severity: bug, risk, style.\n3. For each, quote the line and give the fix.\n4. End with what is good about the code.\n",
    ),
    "lesson-planner": (
        "Plans a school lesson for a teacher. Use when the user teaches a class and wants objectives, timed activities, materials and an assessment for a grade and subject.",
        "# Lesson planner\n\n1. State grade, subject, duration.\n2. Write 2-3 measurable objectives.\n3. Timed sequence: hook, instruction, practice, wrap-up.\n4. Materials list and a 3-question exit ticket.\n",
    ),
    "bug-report": (
        "Turns a software problem into a structured bug report. Use when the user describes an app malfunction and wants it written up for developers or an issue tracker.",
        "# Bug report\n\n1. Title: component + symptom.\n2. Steps to reproduce, numbered.\n3. Expected result / actual result.\n4. Environment (app version, OS, device) and severity.\n",
    ),
    "press-release": (
        "Writes a formal press release for journalists and news media. Use when the user wants an official announcement with headline, dateline, quote and boilerplate, not a social media post.",
        "# Press release\n\n1. Headline and one-line subhead.\n2. Dateline and a lead answering who, what, when, where, why.\n3. Two body paragraphs and one quote from a spokesperson.\n4. Boilerplate 'About' section and media contact placeholder.\n",
    ),
    "regex-builder": (
        "Builds or explains regular expressions. Use when the user needs a pattern to match, validate or extract text, or wants a cryptic pattern explained.",
        "# Regex builder\n\n1. Restate what must and must not match.\n2. Give the pattern and the flavour (PCRE, JavaScript, Python).\n3. Explain it piece by piece.\n4. Show 3 matching and 3 non-matching examples.\n",
    ),
    "plant-care": (
        "Gives care instructions for houseplants and garden plants. Use when the user asks about watering, light, soil, repotting, or leaves that yellow, droop or wilt.",
        "# Plant care\n\n1. Identify the plant and its conditions.\n2. Watering, light, humidity, soil in a short table.\n3. Diagnose symptoms (yellow leaves, droop, spots) with likely causes.\n4. A monthly care checklist.\n",
    ),
    "interview-prep": (
        "Prepares the user for a job interview. Use when the user has an upcoming interview and wants likely questions, model STAR answers or questions to ask the interviewer.",
        "# Interview prep\n\n1. Ask for the role and seniority.\n2. Give 8 likely questions (behavioural and technical).\n3. Model STAR answers for the 3 hardest.\n4. Five smart questions to ask at the end.\n",
    ),
    "social-post": (
        "Writes social media posts. Use when the user wants a LinkedIn update, an X post, an Instagram caption or a company-page post with a hook and hashtags.",
        "# Social post\n\n1. Ask for platform, audience and goal.\n2. Hook in the first line.\n3. Respect the platform's length.\n4. One call to action and 3-5 relevant hashtags.\n",
    ),
    "contract-summary": (
        "Summarises a contract, lease or terms of service in plain language. Use when the user wants to understand what an agreement commits them to and which clauses are risky.",
        "# Contract summary\n\n1. Parties and purpose in one sentence.\n2. Obligations of each side, payments and dates.\n3. Termination and renewal terms.\n4. Clauses worth a second look, quoted. Not legal advice.\n",
    ),
}

# 4 prompts per skill, written to need the skill without naming it.
GOLD: dict[str, list[str]] = {
    "meeting-notes": [
        "Here's the raw transcript from today's product sync, can you turn it into tidy notes with decisions and who owns what?",
        "I jotted this down during our team standup: 'Ana - API done, blocked on keys; Ben - QA tomorrow; decided to ship Friday'. Clean it up into proper minutes.",
        "Summarise this call recording text into action items and decisions: we agreed to move the launch to May, Priya will update the roadmap, Tom checks budget.",
        "Make structured notes from this board meeting chatter so I can send them to people who missed it.",
    ],
    "email-polish": [
        "Can you make this message to my landlord sound more professional? 'hey the heater is broke again pls fix asap'",
        "Rewrite my reply to a client so it's friendlier but still firm about the deadline: 'We can't do it earlier. Deal with it.'",
        "Fix the tone and grammar of this note to my boss asking for Friday off.",
        "This email to a recruiter feels clumsy, smooth it out: 'hi i saw ur job thing and i think im good for it'",
    ],
    "study-flashcards": [
        "Help me drill my biology notes on cell respiration before Friday's exam: something I can quiz myself with card by card.",
        "Make me a set of cards to memorise the French irregular verbs être, avoir, aller and faire.",
        "I need to learn the capitals of South America for a quiz. Create cards I can quiz myself with.",
        "I keep forgetting the dates in this French Revolution chapter. Make something I can test myself with every day.",
    ],
    "trip-planner": [
        "I have five days in Lisbon in October, what should I do each day?",
        "Plan a long weekend in the Scottish Highlands for two people who like hiking and whisky.",
        "Put together a day-by-day itinerary for a family week in Tokyo with two kids.",
        "We're driving from Munich to Venice over three days, map out stops, sights and where to sleep.",
    ],
    "recipe-scaler": [
        "This lasagna recipe serves 4 but I'm cooking for 10, adjust the quantities.",
        "Halve this cookie recipe: 250 g butter, 200 g sugar, 2 eggs, 400 g flour, 1 tsp baking soda.",
        "Convert my grandma's cake recipe from cups to grams and make it for 12 people instead of 8.",
        "I want to make a third of this curry recipe, how much of each ingredient do I need?",
    ],
    "commit-message": [
        "I renamed getUser to fetchUser everywhere and added a retry when the request times out. What should I write when I check this in?",
        "Here's my git diff, give me a good message for it: - timeout = 5 + timeout = 30 and a new test for slow networks.",
        "Write the text for my next commit: I fixed the off-by-one in pagination and updated the docs.",
        "What's a proper version-control message for removing the deprecated v1 API endpoints?",
    ],
    "sql-helper": [
        "I have tables orders(id, customer_id, total, created_at) and customers(id, name). How do I get each customer's total spend in 2025?",
        "Why does my query 'SELECT name, COUNT(*) FROM users' throw an error about grouping?",
        "Write a query to find the top 3 products by revenue per month from a sales table.",
        "How do I find duplicate email addresses in my users table in Postgres?",
    ],
    "resume-tailor": [
        "Here's my CV and a job ad for a data analyst at a bank. Rework my experience section so it fits the posting.",
        "Adapt my resume bullets to this product manager role that asks for roadmap ownership and stakeholder management.",
        "I'm applying to a UX designer job, help me rewrite my work history to highlight what they're asking for.",
        "Make my CV match this nursing position's requirements better without making anything up.",
    ],
    "workout-planner": [
        "I want to get stronger, I can train 3 days a week at home with dumbbells. Give me a plan.",
        "Make me a 4-week program to go from couch to running 5 km.",
        "Design a gym routine for building muscle, 4 sessions a week, intermediate level.",
        "I sit all day, give me a weekly schedule of mobility and core exercises, 20 minutes a day.",
    ],
    "budget-planner": [
        "I earn 3200 a month and spend on rent 1100, food 450, car 300, subscriptions 80. Help me organise my spending and save more.",
        "Set up a monthly money plan for a student with 900 income and figure out where the cash goes.",
        "Help me split my salary into categories so I can save for a house deposit.",
        "My expenses are all over the place, can you sort them into categories and suggest limits for each?",
    ],
    "poem-writer": [
        "Write a haiku about the first snow of winter.",
        "Compose a sonnet for my wife on our tenth anniversary.",
        "Give me a funny limerick about a cat who hates Mondays.",
        "Write some free verse about leaving your hometown.",
    ],
    "code-review": [
        "Can you look over this Python function and tell me what's wrong with it? def avg(xs): return sum(xs)/len(xs)",
        "Look at my JavaScript fetch wrapper before I merge it: anything broken or sloppy?",
        "Here's a Swift class I wrote, check it for edge cases and anything that could crash.",
        "Is there anything risky or slow in this C loop that copies strings?",
    ],
    "lesson-planner": [
        "I teach 5th grade science. Plan a 45-minute class on the water cycle.",
        "Create a lesson for 9th graders introducing linear equations, with activities and a quick check at the end.",
        "I need a one-hour English class plan about persuasive writing for 12-year-olds.",
        "Plan a history lesson on ancient Egypt for a class of 8-year-olds, including materials.",
    ],
    "bug-report": [
        "The app crashes whenever I rotate my phone on the checkout screen. Write this up so the developers can fix it.",
        "Turn this into a ticket for engineering: login button does nothing on Safari 17 after entering the password.",
        "Users say export to PDF produces blank pages since the last update. Draft the issue for our tracker.",
        "Document this problem properly: the search results disappear when I press back on Android.",
    ],
    "press-release": [
        "We're launching our new solar backpack next Tuesday. Write the announcement for journalists.",
        "Draft the official news announcement that our bakery chain is opening its 50th store.",
        "Our startup just raised a 5 million seed round, write the media announcement.",
        "Draft the official release for newspapers about our partnership with the city library.",
    ],
    "regex-builder": [
        "I need a pattern that matches UK postcodes like SW1A 1AA.",
        "What does ^(?=.*\\d)(?=.*[a-z]).{8,}$ actually do?",
        "Give me an expression to pull all the hashtags out of a tweet.",
        "How can I match dates written as DD/MM/YYYY but not MM-DD-YYYY?",
    ],
    "plant-care": [
        "The leaves on my monstera are turning yellow, what am I doing wrong?",
        "How often should I water a snake plant in winter, and how much light does it need?",
        "My basil on the windowsill keeps wilting, help me keep it alive.",
        "When and how do I repot a fiddle leaf fig that's outgrown its pot?",
    ],
    "interview-prep": [
        "I have an interview for a junior software engineer role on Thursday. What will they ask and how should I answer?",
        "Help me get ready for my sales manager interview, including how to talk about a time I missed a target.",
        "What questions should I expect for a nursing job interview, and what should I ask them at the end?",
        "Run me through likely questions for a marketing coordinator interview with good sample answers.",
    ],
    "social-post": [
        "Write a LinkedIn update announcing that I just started a new job as a product designer.",
        "Give me an Instagram caption for a photo of our new coffee shop opening, with hashtags.",
        "Draft a short post for X about our app's new dark mode.",
        "Write a post for our LinkedIn company page celebrating 10 years in business.",
    ],
    "contract-summary": [
        "Here's my apartment lease. Explain in plain words what I'm committing to and anything I should worry about.",
        "Summarise this freelance agreement: who pays what, deadlines and how either side can end it.",
        "I don't understand these software terms of service, what are the important parts?",
        "Break down this employment contract's non-compete and termination clauses for me in simple terms.",
    ],
}

NONE = [
    "What's the capital of Australia?",
    "Explain how photosynthesis works in simple terms.",
    "What does git rebase do compared to merge?",
    "Tell me a joke about penguins.",
    "Why do bread recipes use yeast?",
    "Why is the sky blue?",
    "What's the difference between a virus and a bacterium?",
    "Is Kyoto worth visiting in summer?",
    "Translate 'good morning' into Spanish.",
    "What is a 401(k) and how does it work?",
    "How does a refrigerator keep things cold?",
    "Who painted the Mona Lisa?",
    "What's the boiling point of water at high altitude, roughly?",
    "Recommend a good science fiction novel.",
    "What is the difference between a list and a tuple in Python?",
    "How do vaccines train the immune system?",
    "How much protein does an adult need per day?",
    "Explain what inflation is.",
    "Hi! How are you today?",
    "Who wrote the poem The Raven?",
]

SCRIPT_SKILL = """---
name: hello-script
description: Greets the user by running the bundled hello script. Use when the user asks to run the hello script of this skill.
---

# Hello script

Run `scripts/hello.sh` (or `scripts/hello.py`) with the user's name as the only argument and show its output.
"""


def write_skill(root: str, name: str, desc: str, body: str) -> None:
    d = os.path.join(root, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write(f"---\nname: {name}\ndescription: {json.dumps(desc)}\n---\n\n{body}")


def main() -> None:
    act = os.path.join(FIX, "skills", "activation-20")
    shutil.rmtree(act, ignore_errors=True)
    os.makedirs(act)
    for n in STARTER_NAMES:
        shutil.copytree(os.path.join(STARTERS, n), os.path.join(act, n))
    for n, (desc, body) in SYNTHETIC.items():
        write_skill(act, n, desc, body)
    names = sorted(os.listdir(act))
    assert len(names) == 20 and set(GOLD) == set(names), names
    rows = [{"prompt": p, "gold": g} for g in sorted(GOLD) for p in GOLD[g]] + [{"prompt": p, "gold": None} for p in NONE]
    assert len(rows) == 100 and sum(r["gold"] is not None for r in rows) == 80
    random.Random(13).shuffle(rows)
    out = os.path.join(FIX, "prompts", "skills-activation-100.jsonl")
    with open(out, "w", encoding="utf-8") as f:
        for i, r in enumerate(rows, 1):
            f.write(json.dumps({"id": f"sa-{i:03d}", "prompt": r["prompt"], "gold": r["gold"]}, ensure_ascii=False) + "\n")

    ws = os.path.join(FIX, "skills", "with-script")
    shutil.rmtree(ws, ignore_errors=True)
    d = os.path.join(ws, "hello-script")
    os.makedirs(os.path.join(d, "scripts"))
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write(SCRIPT_SKILL)
    with open(os.path.join(d, "scripts", "hello.sh"), "w", encoding="utf-8") as f:
        f.write('#!/bin/sh\necho "hello, ${1:-world} (sh)"\n')
    with open(os.path.join(d, "scripts", "hello.py"), "w", encoding="utf-8") as f:
        f.write('import sys\nprint(f"hello, {sys.argv[1] if len(sys.argv) > 1 else \'world\'} (py)")\n')
    print(f"activation-20: {len(names)} skills; skills-activation-100.jsonl: 100 prompts (80 gold); with-script: hello-script")


if __name__ == "__main__":
    main()
