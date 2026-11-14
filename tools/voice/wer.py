#!/usr/bin/env python3
"""WER / CER scorer for the voice ATs (M3.T05 step 3; NFR-V9, AT-284). Python 3 stdlib only; run with `python3 -I`.

Normalisation (both sides): Unicode NFKC, lowercase, punctuation and symbols removed (Unicode categories P* / S*),
whitespace collapsed; Arabic: harakat / tatweel removed and alef / yeh / teh-marbuta forms unified (orthographic
variants, not recognition errors). Metric: word error rate for space-delimited scripts (en, de, ar, …); character
error rate for ja / zh (no word boundaries) — A-M3-02: NFR-V9's WER applies as CER for those two scripts.

  tools/voice/wer.py --in build/at/AT-284/wer.json --budget NFR-V9 --tier T1      # check a results file
  tools/voice/wer.py --ref "a b c" --hyp "a c" --lang en                           # one pair

`--in` reads {"rows": [{"lang", "ref", "hyp", "mode", "engine", …}, …]} (WERFixtureTests), writes per-language and
per-mode scores back under "scores", and exits 1 when a language is over the tier budget (mode `auto` by default).
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata

CER_LANGS = {"ja", "zh"}
# NFR-V9: WER ≤ 6 % (T1+) and ≤ 10 % (T0) (docs/research/02-target/nfr.md).
BUDGET = {"NFR-V9": {"T0": 0.10, "T1": 0.06, "T2": 0.06, "T3": 0.06, "T4": 0.06}}
AR_FOLD = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ـ": None})


def normalise(text: str, lang: str) -> str:
    t = unicodedata.normalize("NFKC", text).lower()
    if lang == "ar":
        t = "".join(c for c in t if not ("ً" <= c <= "ٟ" or c == "ٰ")).translate(AR_FOLD)
    t = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in t)
    return " ".join(t.split())


def units(text: str, lang: str) -> list[str]:
    t = normalise(text, lang)
    return [c for c in t if not c.isspace()] if lang in CER_LANGS else t.split()


def edits(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j - 1] + (r != h), prev[j] + 1, cur[j - 1] + 1)
        prev = cur
    return prev[-1]


def score(rows: list[dict]) -> dict:
    out: dict[str, dict] = {}
    for r in rows:
        lang, mode = r["lang"], r.get("mode", "auto")
        ref, hyp = units(r["ref"], lang), units(r["hyp"], lang)
        s = out.setdefault(mode, {}).setdefault(lang, {"errors": 0, "units": 0, "n": 0, "metric": "cer" if lang in CER_LANGS else "wer",
                                                       "engines": {}})
        s["errors"] += edits(ref, hyp)
        s["units"] += len(ref)
        s["n"] += 1
        e = r.get("engine", "?")
        s["engines"][e] = s["engines"].get(e, 0) + 1
    for langs in out.values():
        for s in langs.values():
            s["rate"] = round(s["errors"] / max(1, s["units"]), 4)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--in", dest="inp")
    ap.add_argument("--budget", default="NFR-V9")
    ap.add_argument("--tier", default="T1")
    ap.add_argument("--mode", default="auto", help="mode whose scores are checked against the budget")
    ap.add_argument("--ref")
    ap.add_argument("--hyp")
    ap.add_argument("--lang", default="en")
    a = ap.parse_args(argv)
    if a.ref is not None:
        ref, hyp = units(a.ref, a.lang), units(a.hyp or "", a.lang)
        print(f"{'cer' if a.lang in CER_LANGS else 'wer'} {edits(ref, hyp) / max(1, len(ref)):.4f}")
        return 0
    if not a.inp:
        ap.error("--in or --ref")
    data = json.load(open(a.inp))
    scores = score(data["rows"])
    data["scores"] = scores
    with open(a.inp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    limit = BUDGET[a.budget][a.tier]
    bad = []
    for mode, langs in sorted(scores.items()):
        for lang, s in sorted(langs.items()):
            over = s["rate"] > limit
            if over and mode == a.mode:
                bad.append(lang)
            print(f"{mode:6} {lang}: {s['metric'].upper()} {100 * s['rate']:.2f} % (n {s['n']}, {s['units']} {'chars' if s['metric'] == 'cer' else 'words'}; "
                  f"engines {s['engines']}) {'OVER' if over else 'ok'} (≤ {100 * limit:.0f} %)")
    print(f"wer.py: {a.budget} {a.tier} mode {a.mode}: " + ("pass" if not bad else f"over budget: {bad}"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
