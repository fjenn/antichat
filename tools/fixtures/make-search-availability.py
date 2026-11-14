#!/usr/bin/env python3
"""M7.T01 step 8 (AT-248 c3): `search-availability-100.jsonl` + one saved SERP per engine per query.

  make-search-availability.py [--fixtures DIR]              write prompts/search-availability-100.jsonl (seed 7)
  make-search-availability.py --capture [--fixtures DIR]    + fetch web/serp-snapshots/<engine>/<qid>.html|json

100 neutral queries: 40 news-ish, 30 encyclopedic, 30 how-to, built from fixed word lists with random.Random(7); no
personal data. `--capture` needs the network (Q-007) and sends exactly the request the app's engine builds (same URL
template, the safe-search *off* parameter, the vendored scrapers' browser User-Agent), one request per engine every
1.5 s (Wikipedia 3 s, Brave 6 s). A non-200 answer or a bot-check/captcha page is saved as returned (the replay then fails that engine, as the
live run would) and an engine is skipped for the rest of the run after 3 such answers in a row: the capture never
retries around a challenge. `capture-log.json` records per engine what came back. Run with `python3 -I`.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

NEWS_TOPICS = ["electric cars", "solar power", "space telescope", "football league", "chess championship",
               "rail strike", "interest rates", "olympic games", "climate summit", "smartphone launch",
               "film festival", "tennis open", "volcano eruption", "election results", "stock market",
               "marathon", "wildfire", "heat wave", "mars rover", "vaccine research"]
NEWS_FORMS = ["latest {t} news", "{t} news this week", "{t} update today", "what happened with {t} recently"]
ENCYC_TOPICS = ["printing press", "photosynthesis", "roman empire", "great barrier reef", "theory of relativity",
                "silk road", "mount everest", "ada lovelace", "periodic table", "amazon river", "byzantine empire",
                "black holes", "jazz music", "industrial revolution", "pyramids of giza", "dna double helix",
                "renaissance painting", "plate tectonics", "honey bees", "the moon landing"]
ENCYC_FORMS = ["history of {t}", "what is {t}", "{t} facts", "who discovered {t}"]
HOWTO_TASKS = ["bake sourdough bread", "change a bike tire", "grow tomatoes", "tie a bowline knot",
               "make cold brew coffee", "clean a cast iron pan", "fold a fitted sheet", "learn touch typing",
               "repot a houseplant", "sharpen a kitchen knife", "brew green tea", "remove a stripped screw",
               "start a compost bin", "paint a room", "make a paper airplane", "fix a leaky faucet",
               "plan a vegetable garden", "write a cover letter", "set up a fish tank", "boil an egg"]
HOWTO_FORMS = ["how to {t}", "how do I {t}", "best way to {t}", "{t} step by step"]

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
      "Safari/605.1.15")  # = SearchHTTPClient.userAgents[1] (WebSearchEngine.userAgent)

# Mirrors the code defaults (Packages/Tools/Sources/AntiChatTools/Search/Engines/*): URL template + safe off item.
ENGINES = {
    "duckduckgo": ("https://html.duckduckgo.com/html/?q={q}&kl=wt-wt", "kp=-2", "html"),
    "brave": ("https://search.brave.com/search?q={q}&source=web", "safesearch=off", "html"),
    "mojeek": ("https://www.mojeek.com/search?q={q}", "safe=0", "html"),
    "startpage": ("https://www.startpage.com/sp/search?query={q}&cat=web&t=device&lui=english&language=english"
                  "&segment=organic", "qadf=none", "html"),
    "wikipedia": ("https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch={q}&format=json&srlimit=10",
                  "", "json"),
}
CHALLENGE = ["captcha", "bots use duckduckgo too", "anomaly-modal", "just a moment", "checking your browser",
             "unusual traffic", "are you a robot", "<title>captcha</title>", "anubis", "verifying your request"]
# The JSON API gets the app's own User-Agent (the gate default, NetworkGate.userAgent), as Wikimedia's API policy
# asks; the HTML engines get the browser UA the app's scrapers send. Pacing per engine (seconds between requests).
API_UA = "AntiChat/0.1 (+https://antichat.app/bot)"
PACING = {"wikipedia": 3.0, "brave": 6.0}


def queries() -> list[dict]:
    rng = random.Random(7)
    out: list[dict] = []
    for cat, n, topics, forms in [("news", 40, NEWS_TOPICS, NEWS_FORMS), ("encyclopedic", 30, ENCYC_TOPICS, ENCYC_FORMS),
                                  ("howto", 30, HOWTO_TASKS, HOWTO_FORMS)]:
        seen: set[str] = set()
        while len([q for q in out if q["category"] == cat]) < n:
            q = rng.choice(forms).format(t=rng.choice(topics))
            if q in seen:
                continue
            seen.add(q)
            out.append({"category": cat, "query": q})
    for i, q in enumerate(out, 1):
        q["id"] = f"q{i:03d}"
    return [{"id": q["id"], "category": q["category"], "query": q["query"]} for q in out]


def url_for(engine: str, query: str) -> str:
    template, safe, _ = ENGINES[engine]
    u = template.replace("{q}", urllib.parse.quote_plus(query))
    return u + ("&" + safe if safe else "")


def capture_engine(engine: str, qs: list[dict], out: Path, log: dict, lock: threading.Lock) -> None:
    _, _, ext = ENGINES[engine]
    d = out / engine
    d.mkdir(parents=True, exist_ok=True)
    streak, rows = 0, []
    for q in qs:
        if streak >= 3:
            rows.append({"id": q["id"], "status": "skipped (3 blocked answers in a row)"})
            continue
        req = urllib.request.Request(url_for(engine, q["query"]), headers={
            "User-Agent": API_UA if ext == "json" else UA, "Accept-Language": "en-US,en;q=0.9",
            "Accept": "application/json" if ext == "json" else "text/html,application/xhtml+xml"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                status, body = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read()
        except Exception as e:  # network error: nothing saved
            rows.append({"id": q["id"], "status": f"error: {type(e).__name__}"})
            streak += 1
            time.sleep(PACING.get(engine, 1.5))
            continue
        low = body[:200_000].decode("utf-8", "replace").lower()
        blocked = status != 200 or any(c in low for c in CHALLENGE)
        streak = streak + 1 if blocked else 0
        (d / f"{q['id']}.{ext}").write_bytes(body)
        rows.append({"id": q["id"], "status": status, "blocked": blocked, "bytes": len(body)})
        time.sleep(PACING.get(engine, 1.5))
    with lock:
        log[engine] = {"saved": sum(1 for r in rows if "bytes" in r),
                       "blocked": sum(1 for r in rows if r.get("blocked")),
                       "skipped": sum(1 for r in rows if str(r["status"]).startswith("skipped")), "rows": rows}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    ap.add_argument("--capture", action="store_true")
    ap.add_argument("--engines", default=",".join(ENGINES))
    a = ap.parse_args()
    fx = Path(a.fixtures)
    qs = queries()
    p = fx / "prompts" / "search-availability-100.jsonl"
    p.write_text("".join(json.dumps(q, ensure_ascii=False) + "\n" for q in qs))
    print(f"wrote {p} ({len(qs)} queries)")
    if not a.capture:
        return 0
    out = fx / "web" / "serp-snapshots"
    log_path = out / "capture-log.json"
    log: dict = json.loads(log_path.read_text()) if log_path.exists() else {}  # --engines re-captures merge in
    lock = threading.Lock()
    threads = [threading.Thread(target=capture_engine, args=(e, qs, out, log, lock)) for e in a.engines.split(",")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    meta = log.get("_meta", {})
    for e in a.engines.split(","):
        meta[e] = {"captured": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "user_agent": API_UA if ENGINES[e][2] == "json" else UA, "pacing_s": PACING.get(e, 1.5)}
    meta["rule"] = "saved as returned; engine skipped after 3 blocked answers in a row; bot checks never retried"
    log["_meta"] = meta
    (out / "capture-log.json").write_text(json.dumps(log, indent=1, sort_keys=True) + "\n")
    for e in a.engines.split(","):
        print(f"{e}: saved {log[e]['saved']}, blocked {log[e]['blocked']}, skipped {log[e]['skipped']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
