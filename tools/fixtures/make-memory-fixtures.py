#!/usr/bin/env python3
"""Memory decider fixtures (M8.T02 step 5; AT-242 AC3). Synthetic persona facts, hand-written, CC0.

  make-memory-fixtures.py [--out fixtures/memory]

paraphrase-100.jsonl  {"topic","existing","new","expected":"UPDATE","kind":"single|multi"}: 10 topics × 10 pairs
                      (7 single-sentence + 3 multi-attribute each); "new" restates "existing" in other words.
distinct-20.jsonl     {"topic","existing","new","expected":"ADD"}: same topic, a different fact (the decider must not
                      pass by always updating).
sensitive-30.jsonl    {"text","category"}: 25 facts over the five R-060 AC3 categories + 5 "none".
Order is shuffled with seed 20261030 so the file is stable.
"""
from __future__ import annotations

import argparse
import json
import os
import random

P = {
    "Food": [
        ("I'm vegetarian", "I don't eat meat"), ("I'm allergic to peanuts", "Peanuts give me an allergic reaction"),
        ("My favourite cuisine is Thai", "Thai food is what I like most"), ("I drink my coffee black", "I take coffee without milk or sugar"),
        ("I can't stand cilantro", "I really dislike coriander leaves"), ("I eat breakfast at 7 every day", "Every morning I have breakfast at seven"),
        ("I'm lactose intolerant", "Dairy upsets my stomach because of lactose"),
        ("I'm vegan and avoid gluten", "I follow a vegan diet and don't eat gluten"),
        ("I love spicy food and sushi", "Sushi and very spicy dishes are my favourites"),
        ("I cook dinner at home and rarely order takeout", "I hardly ever get takeaway; I make dinner myself"),
    ],
    "Work": [
        ("I work as a nurse", "My job is nursing"), ("I work from home on Fridays", "Fridays are my remote work day"),
        ("My manager is called Priya", "Priya is my boss"), ("I'm a backend engineer at a fintech", "I do server-side engineering for a financial technology company"),
        ("I start work at 8:30", "My workday begins at half past eight"), ("I hate long meetings", "Lengthy meetings annoy me"),
        ("I'm looking for a new job", "I'm currently job hunting"),
        ("I teach maths and physics at a high school", "I'm a secondary school teacher for mathematics and physics"),
        ("I work night shifts at the hospital three times a week", "Three nights a week I do night duty at the hospital"),
        ("I freelance as a translator from German and French", "I'm a self-employed translator working from French and German"),
    ],
    "Family": [
        ("I have two daughters", "I'm the father of two girls"), ("My wife's name is Ana", "Ana is my wife"),
        ("My mother lives in Porto", "Mum lives in Porto"), ("I have a younger brother", "I've got a little brother"),
        ("My son is 7 years old", "My boy is seven"), ("My parents are divorced", "My mum and dad split up"),
        ("My grandmother turns 90 in May", "Grandma will be ninety this May"),
        ("I have a son named Leo and a daughter named Mia", "My kids are Leo and Mia, a boy and a girl"),
        ("My sister is a doctor and lives in Lyon", "My sister works as a physician in Lyon"),
        ("My husband Tom works as a chef and loves cycling", "Tom, my husband, is a cook who is into cycling"),
    ],
    "Home": [
        ("I live in Berlin", "Berlin is where I live"), ("I rent a small flat", "I live in a little rented apartment"),
        ("I have a balcony garden", "I grow plants on my balcony"), ("My flat is on the fourth floor", "I live four floors up"),
        ("I live alone", "Nobody else lives with me"), ("My commute is 40 minutes", "It takes me forty minutes to get to work"),
        ("I'm moving house next month", "Next month I move to a new home"),
        ("I live in a two-bedroom house in Utrecht with a garden", "My home is a house in Utrecht with two bedrooms and a yard"),
        ("I share a flat with two friends near the university", "I live with two friends in a flat close to the uni"),
        ("I own an old farmhouse that I'm renovating", "I'm doing up the old farmhouse I bought"),
    ],
    "Hobbies": [
        ("I play the piano", "I'm a piano player"), ("I go climbing every weekend", "Every weekend I go rock climbing"),
        ("I collect vinyl records", "I have a vinyl record collection"), ("I'm learning to paint with watercolours", "I'm taking up watercolour painting"),
        ("I run half marathons", "I do half-marathon races"), ("I love board games", "Board games are my thing"),
        ("I knit sweaters in winter", "In the winter I knit jumpers"),
        ("I play chess online and in a local club", "I'm in a chess club and also play chess on the internet"),
        ("I sail on weekends and fish in summer", "At weekends I go sailing, and I fish during the summer"),
        ("I photograph birds and edit the pictures in Lightroom", "I do bird photography and process the shots with Lightroom"),
    ],
    "Pets": [
        ("I have a cat named Miso", "My cat is called Miso"), ("My dog is a border collie", "I own a border collie"),
        ("My cat is 12 years old", "My cat is twelve"), ("I'm allergic to cats", "Cats make me allergic"),
        ("I want to adopt a dog", "I'm planning to get a rescue dog"), ("My rabbit lives in the garden", "I keep my bunny outdoors in the garden"),
        ("My dog is afraid of thunder", "Thunderstorms scare my dog"),
        ("I have two cats, Miso and Tofu", "My two cats are called Tofu and Miso"),
        ("My parrot Kiwi talks and is 20 years old", "Kiwi, my twenty-year-old parrot, can speak"),
        ("My dog Bruno is a labrador who needs a special diet", "Bruno, my lab, has to eat special food"),
    ],
    "Travel": [
        ("I'm going to Japan in April", "In April I'm travelling to Japan"), ("I hate flying", "I really don't like planes"),
        ("I've been to 30 countries", "I've visited thirty countries"), ("I prefer trains to planes", "I'd rather take the train than fly"),
        ("My favourite city is Lisbon", "Lisbon is the city I love most"), ("I always travel with carry-on only", "I never check a bag when I travel"),
        ("I get seasick on boats", "Boats make me seasick"),
        ("I'm planning a road trip through Norway in July with my partner", "In July my partner and I will drive around Norway"),
        ("I backpacked across South America for six months", "I spent half a year backpacking in South America"),
        ("I visit my family in Brazil every Christmas", "Each Christmas I fly to Brazil to see my family"),
    ],
    "Health": [
        ("I wear glasses", "I need glasses to see"), ("I go to the gym three times a week", "I work out at the gym three days a week"),
        ("I sleep about six hours a night", "I usually get around six hours of sleep"), ("I'm trying to cut down on sugar", "I want to eat less sugar"),
        ("I do yoga in the morning", "Mornings I practise yoga"), ("I'm training for a 10k", "I'm preparing for a ten-kilometre run"),
        ("I don't drink alcohol", "I never drink alcohol"),
        ("I swim twice a week and cycle to work", "I go swimming two times a week and ride my bike to the office"),
        ("I'm a morning person and go to bed by ten", "I'm up early and asleep by 10 pm"),
        ("I meditate daily and keep a journal", "Every day I meditate and write in my diary"),
    ],
    "Preferences": [
        ("I prefer short answers", "Keep replies brief for me"), ("I like examples in Python", "Show me code samples in Python"),
        ("Please use metric units", "I want measurements in metric"), ("I prefer dark mode", "I like dark themes"),
        ("Call me Sam", "My name is Sam, use that"), ("I like bullet points", "Lists with bullets work best for me"),
        ("Answer me in Dutch", "I'd like responses in Dutch"),
        ("I prefer formal language and British spelling", "Write to me formally and spell things the British way"),
        ("Use 24-hour time and DD/MM/YYYY dates", "Show times on a 24-hour clock and dates as day/month/year"),
        ("I want sources linked and no emojis", "Link your sources and leave out emojis"),
    ],
    "Learning": [
        ("I'm learning Spanish", "I'm studying Spanish"), ("I'm doing a master's in data science", "I'm a data science master's student"),
        ("I read about one book a month", "I finish roughly a book every month"), ("I'm learning to code in Rust", "I'm picking up Rust programming"),
        ("I struggle with statistics", "Statistics is hard for me"), ("I take guitar lessons on Tuesdays", "Tuesdays I have my guitar lesson"),
        ("I'm preparing for the bar exam", "I'm studying for the bar"),
        ("I study Japanese and Korean on Duolingo", "I use Duolingo to learn Korean and Japanese"),
        ("I'm taking an evening course in accounting and Excel", "At night I attend a class on bookkeeping and spreadsheets"),
        ("I want to learn sailing and get a skipper licence", "My goal is to learn to sail and earn a skipper's certificate"),
    ],
}

D = [
    ("Food", "I'm vegetarian", "I love Italian desserts"), ("Food", "I drink my coffee black", "I'm allergic to shellfish"),
    ("Work", "I work as a nurse", "I want to run a marathon next year"), ("Work", "My manager is called Priya", "I commute by bike"),
    ("Family", "I have two daughters", "My father is a retired pilot"), ("Family", "My wife's name is Ana", "My cousin lives in Toronto"),
    ("Home", "I live in Berlin", "My kitchen has a gas stove"), ("Home", "I rent a small flat", "I'm saving up to buy a car"),
    ("Hobbies", "I play the piano", "I collect old maps"), ("Hobbies", "I go climbing every weekend", "I watch Formula 1 races"),
    ("Pets", "I have a cat named Miso", "I'd like a fish tank someday"), ("Pets", "My dog is a border collie", "My neighbour has chickens"),
    ("Travel", "I'm going to Japan in April", "I've never been to Africa"), ("Travel", "I hate flying", "My passport expires in 2027"),
    ("Health", "I wear glasses", "I had my knee operated on in 2022"), ("Health", "I don't drink alcohol", "I take vitamin D in winter"),
    ("Preferences", "I prefer short answers", "I like jokes in replies"), ("Preferences", "Please use metric units", "My timezone is CET"),
    ("Learning", "I'm learning Spanish", "I play the violin badly"), ("Learning", "I struggle with statistics", "My favourite author is Ursula K. Le Guin"),
]

S = [
    ("I have type 2 diabetes", "health"), ("I'm on antidepressants", "health"), ("I had cancer five years ago", "health"),
    ("I'm pregnant", "health"), ("I have ADHD", "health"),
    ("I'm gay", "sexuality"), ("I'm bisexual", "sexuality"), ("My girlfriend and I are both women", "sexuality"),
    ("I'm asexual", "sexuality"), ("I'm questioning my sexuality", "sexuality"),
    ("I'm a practising Muslim", "religion"), ("I go to church every Sunday", "religion"), ("I'm an atheist", "religion"),
    ("I keep kosher", "religion"), ("I'm Buddhist", "religion"),
    ("I vote Green", "politics"), ("I'm a member of the Labour party", "politics"), ("I'm a libertarian", "politics"),
    ("I campaign for the conservatives", "politics"), ("I'm a socialist", "politics"),
    ("I earn 85,000 euros a year", "finances"), ("I have 20,000 in credit card debt", "finances"), ("My mortgage is 1,400 a month", "finances"),
    ("I'm saving for retirement in an index fund", "finances"), ("I declared bankruptcy in 2019", "finances"),
    ("I like jazz", "none"), ("I live near the sea", "none"), ("My favourite colour is green", "none"),
    ("I have a twin brother", "none"), ("I work in marketing", "none"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "fixtures", "memory"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(20261030)
    para = [{"topic": t, "existing": e, "new": n, "expected": "UPDATE", "kind": "single" if i < 7 else "multi"}
            for t, pairs in P.items() for i, (e, n) in enumerate(pairs)]
    assert len(para) == 100 and sum(p["kind"] == "multi" for p in para) == 30
    dist = [{"topic": t, "existing": e, "new": n, "expected": "ADD"} for t, e, n in D]
    sens = [{"text": t, "category": c} for t, c in S]
    assert len(dist) == 20 and len(sens) == 30 and sum(s["category"] != "none" for s in sens) == 25
    for name, rows in (("paraphrase-100.jsonl", para), ("distinct-20.jsonl", dist), ("sensitive-30.jsonl", sens)):
        rng.shuffle(rows)
        with open(os.path.join(a.out, name), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"wrote {name} ({len(rows)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
