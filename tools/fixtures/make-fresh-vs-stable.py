#!/usr/bin/env python3
"""fresh-vs-stable-200 (M7.T05, R-228 / NFR-U12): 100 prompts that need current information and 100 that do not,
labelled, in the 6 router languages (mostly English). Templates × topics, seed 19, deterministic; our own text (CC0),
no personal data. Fresh prompts include ones with no obvious cue word ("Who runs OpenAI?") and stable prompts include
cue-word traps ("Explain how a weather forecast model works"), so the term list cannot simply be fitted to the set.
Labels were reviewed by an independent agent (fixtures/prompts/SOURCES.md).

  python3 -I tools/fixtures/make-fresh-vs-stable.py --out <fixtures>/prompts/fresh-vs-stable-200.jsonl
"""
import argparse, json, random

FRESH = [
    # weather / time-bound
    ("en", "What's the weather in {city} today?"), ("en", "Will it rain in {city} tomorrow?"),
    ("en", "Is it snowing in {city} right now?"), ("en", "What's the forecast for {city} this weekend?"),
    # prices / markets
    ("en", "What is the price of {coin} right now?"), ("en", "How is {stock} stock doing today?"),
    ("en", "What's the current exchange rate from euros to {cur}?"), ("en", "How much does a {car} cost these days?"),
    # sports / results
    ("en", "Who won the {team} game last night?"), ("en", "What was the score of yesterday's {league} final?"),
    ("en", "Who is leading the {league} this season?"), ("en", "Did {team} win their match this week?"),
    # news / events
    ("en", "What are the latest headlines about {topic}?"), ("en", "Any news on {topic}?"),
    ("en", "What happened with {topic} this week?"), ("en", "Summarise today's news about {topic}"),
    # versions / releases
    ("en", "What's the latest version of {software}?"), ("en", "When does the next {product} come out?"),
    ("en", "Has {software} released a new update recently?"), ("en", "Is {product} out yet?"),
    # office holders / no cue word
    ("en", "Who is the CEO of {company}?"), ("en", "Who runs {company} now?"), ("en", "Who is the president of {country}?"),
    ("en", "Is {shop} open on Sunday?"), ("en", "What time does {shop} close tonight?"),
    # explicit later years
    ("en", "What were the biggest tech stories of 2026?"), ("en", "Who won the Ballon d'Or in 2026?"),
    ("en", "List the films nominated for best picture in 2027"),
    # other languages
    ("de", "Wie wird das Wetter morgen in {city}?"), ("de", "Was kostet ein {coin} gerade?"), ("de", "Wer hat gestern {team} geschlagen?"),
    ("es", "¿Qué tiempo hace hoy en {city}?"), ("es", "¿Cuál es el precio actual del {coin}?"), ("es", "¿Quién ganó el partido de {team} ayer?"),
    ("fr", "Quelle est la météo à {city} demain ?"), ("fr", "Quelles sont les dernières nouvelles sur {topic} ?"),
    ("nl", "Wat is het weer vandaag in {city}?"), ("nl", "Wat is de huidige koers van {coin}?"),
    ("pt", "Como está o tempo hoje em {city}?"), ("pt", "Quem ganhou o jogo do {team} ontem?"),
]
STABLE = [
    ("en", "Explain how a weather forecast model works"), ("en", "Write a short poem about {city} in the rain"),
    ("en", "What is the capital of {country}?"), ("en", "How do I reverse a list in Python?"),
    ("en", "Explain the difference between a stock and a bond"), ("en", "What does 'exchange rate' mean?"),
    ("en", "How does {software} store its configuration files?"), ("en", "Give me a recipe for {dish}"),
    ("en", "What is the boiling point of water at sea level?"), ("en", "Summarise the plot of {book}"),
    ("en", "Who wrote {book}?"), ("en", "Translate 'good morning' into {lang}"),
    ("en", "How do I calculate compound interest?"), ("en", "What's the history of {team}?"),
    ("en", "Explain how {coin} mining works"), ("en", "Write an email asking my landlord to fix the heating"),
    ("en", "What is the current in a circuit with a 10 ohm resistor at 5 volts?"), ("en", "Define photosynthesis"),
    ("en", "How many players are on a {sport} team?"), ("en", "What are the rules of {sport}?"),
    ("en", "Help me plan a 3-day trip itinerary for {city}"), ("en", "What causes the seasons on Earth?"),
    ("en", "Write a news article about a fictional dragon sighting"), ("en", "How do I make my code run faster in Swift?"),
    ("en", "What year did the Berlin Wall fall?"), ("en", "Explain the latest common ancestor concept in biology"),
    ("en", "Proofread this sentence: their going too the store"), ("en", "Why is the sky blue?"),
    ("de", "Erkläre mir, wie ein Elektromotor funktioniert"), ("de", "Schreib ein Gedicht über {city}"),
    ("es", "¿Qué es la fotosíntesis?"), ("es", "Dame una receta de {dish}"),
    ("fr", "Explique la théorie de la relativité"), ("fr", "Écris un poème sur la mer"),
    ("nl", "Leg uit hoe een regenboog ontstaat"), ("nl", "Wat is de hoofdstad van {country}?"),
    ("pt", "Explique como funciona a fotossíntese"), ("pt", "Escreva um poema sobre {city}"),
]
FILL = {
    "city": ["Lisbon", "Hamburg", "Osaka", "Toronto", "Melbourne", "Madrid", "Lyon", "Utrecht", "Porto", "Denver"],
    "coin": ["Bitcoin", "Ethereum", "Solana"], "stock": ["Apple", "Nvidia", "Tesla", "Siemens"],
    "cur": ["dollars", "yen", "Swiss francs"], "car": ["Tesla Model 3", "Toyota Corolla", "VW Golf"],
    "team": ["Barcelona", "the Lakers", "Bayern", "Benfica", "Ajax", "the Yankees"],
    "league": ["Premier League", "NBA", "Champions League", "Bundesliga"],
    "topic": ["the EU AI Act", "the Mars sample return mission", "interest rates", "the climate summit", "chip export rules"],
    "software": ["macOS", "Python", "Xcode", "Node.js", "Blender"], "product": ["iPhone", "PlayStation", "Pixel phone"],
    "company": ["OpenAI", "Twitter", "Intel", "Boeing"], "country": ["Brazil", "France", "Japan", "Kenya", "Chile"],
    "shop": ["the IKEA in Delft", "the Apple Store on Regent Street", "the Louvre"],
    "dish": ["paella", "ramen", "banana bread"], "book": ["Moby-Dick", "Pride and Prejudice", "Dune"],
    "lang": ["Portuguese", "Dutch", "Japanese"], "sport": ["rugby", "volleyball", "cricket"],
}

def fill(rng, t):
    out = t
    for k, vs in FILL.items():
        while "{" + k + "}" in out:
            out = out.replace("{" + k + "}", rng.choice(vs), 1)
    return out

def make(rng, templates, n, label, prefix):
    rows, seen, i = [], set(), 0
    while len(rows) < n:
        lang, t = templates[i % len(templates)]
        i += 1
        p = fill(rng, t)
        if p in seen and i < 10 * n:
            continue
        seen.add(p)
        rows.append({"id": f"{prefix}{len(rows) + 1:03d}", "lang": lang, "prompt": p, "label": label})
    return rows

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rng = random.Random(19)
    rows = make(rng, FRESH, 100, "fresh", "f") + make(rng, STABLE, 100, "stable", "s")
    rng.shuffle(rows)
    with open(a.out, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {a.out}: {len(rows)} rows")

if __name__ == "__main__":
    main()
