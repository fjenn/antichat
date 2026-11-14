#!/usr/bin/env python3
"""Replay end-of-turn rules offline on a TurnEndTraceTests trace (M9.T05). Python 3 stdlib; run with `python3 -I`.

  tools/voice/turn-replay.py build/at/AT-283/trace-<date>.json [--rules rules.json]

A trace holds, per fixture item and bed, every pause the live detector reported: its real silence length, the
pause transcript's finished-sentence flag and smart-turn's probability at candidate silence lengths (32 ms frames).
Each rule set (a `turn-thresholds.json` shape) is replayed like `TurnDetector.check()` / `stableCheck()`: a check at
N ms is decided on the first frame with ≥ N ms of silence; a turn ends at a pause when that decision comes before the
silence ends. Output per rule set: false splits per bed (turn-split-50) and endpointing p50 / p95 on q01…q20.
"""
from __future__ import annotations

import argparse
import json
import math

FRAME = 32


def at(ms: int) -> int:
    """The first 32 ms frame with ≥ ms of silence."""
    return int(math.ceil(ms / FRAME) * FRAME)


def prob(p: dict, ms: int) -> float:
    keys = sorted(int(k) for k in p)
    k = min((x for x in keys if x >= at(ms)), default=keys[-1])
    return p[str(k)]


def decide(pause: dict, r: dict) -> int | None:
    """Silence (ms) at which the rules end the turn at this pause, or None (it never ends here)."""
    p, sentence = pause["p"], pause["sentence"]
    agreement = r.get("requireSentenceEnd", False)
    events: list[int] = []
    st = r.get("sentenceStable")
    if st and agreement and sentence and all(prob(p, ms) >= st["threshold"] for ms in st["probesMs"]):
        events.append(at(max(st["probesMs"])))
    checks = [(r["holdMs"], r["smartTurnThreshold"], False)] + [(c["afterMs"], c["threshold"], False) for c in r.get("rechecks", [])]
    if r.get("sentenceEnd"):
        checks.append((r["sentenceEnd"]["afterMs"], r["sentenceEnd"]["threshold"], True))
    for ms, thr, _ in sorted(checks):
        if agreement and not sentence:
            continue
        if prob(p, ms) >= thr:
            events.append(at(ms))
            break
    if agreement and sentence and r.get("sentenceCapMs"):
        events.append(at(r["sentenceCapMs"]))
    oe = r.get("openEnd")
    if oe and agreement and not sentence and prob(p, oe["afterMs"]) >= oe["threshold"]:
        events.append(at(oe["afterMs"]))
    events.append(at(r["maxSilenceMs"]))
    return min(events)


def replay(trace: dict, r: dict) -> dict:
    out = {"beds": {}}
    for bed, rows in trace.items():
        if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
            continue
        splits, ends = [], []
        for row in rows:
            pauses = row["pauses"]
            if row["kind"] == "pause":
                # every pause but the last (the utterance end) must not end the turn
                for pz in pauses[:-1]:
                    d = decide(pz, r)
                    if d is not None and d <= pz["silence_ms"]:
                        splits.append(row["file"])
                        break
            elif pauses:
                ends.append((decide(pauses[-1], r), row["file"]))
        out["beds"][bed] = {"false_splits": len(splits), "files": splits}
        if ends:
            e = sorted(x for x, _ in ends)
            n = len(e)

            def q(f):
                i = f * (n - 1)
                lo = int(i)
                return e[lo] + (e[min(lo + 1, n - 1)] - e[lo]) * (i - lo)
            out["endpointing"] = {"p50": q(0.5), "p95": q(0.95), "items": {f: x for x, f in ends}}
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--rules", help="JSON array of rule sets (default: tools/voice/turn-tune-m9t05.json)")
    a = ap.parse_args()
    trace = json.load(open(a.trace))
    rules = json.load(open(a.rules or "tools/voice/turn-tune-m9t05.json"))
    for i, r in enumerate(rules):
        res = replay(trace, r)
        beds = " ".join(f"{b}:{v['false_splits']}{v['files']}" for b, v in res["beds"].items())
        ep = res.get("endpointing", {})
        print(f"[{i}] stable={r.get('sentenceStable')} open={r.get('openEnd')} hold={r['holdMs']}@{r['smartTurnThreshold']} "
              f"| p50 {ep.get('p50')} p95 {ep.get('p95')} | {beds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
