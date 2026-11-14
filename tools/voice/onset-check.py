#!/usr/bin/env python3
"""Check forced-aligned word onsets against the waveform (A-M9-T05-AT282b validation). Python 3 stdlib.

  tools/voice/onset-check.py JOBS.json ONSETS.json      (the files of tools/voice/word-onsets.py)

For every word that follows ≥ 100 ms of aligned silence (the previous word's end to this word's start), the acoustic
onset is the first 5 ms frame (2 ms hop) in [prev end, aligned start + 150 ms] whose level is ≥ 15 dB above that gap's
10th-percentile level, and ≥ -50 dBFS — on the waveform and on its first difference (pre-emphasis, which lifts the
weak high-frequency onset of fricatives such as /s/, /f/, /w/); the earlier of the two. Prints aligned − acoustic per word, the median signed difference (bias) and the
share within 20 / 30 ms. Words inside continuous speech have no energy onset to compare and are skipped.
"""
from __future__ import annotations

import json
import math
import sys
import wave
from array import array


def read(path):
    with wave.open(path) as f:
        a = array("h", f.readframes(f.getnframes()))
        return [x / 32768 for x in a], f.getframerate()


def level(x, i, n):
    seg = x[max(0, i): i + n]
    return 10 * math.log10(sum(v * v for v in seg) / max(1, len(seg)) + 1e-12)


def main() -> int:
    jobs = {j["id"]: j for j in json.load(open(sys.argv[1]))}
    on = json.load(open(sys.argv[2]))
    diffs = []
    for jid, r in on.items():
        x0, rate = read(jobs[jid]["wav"])
        x1 = [0.0] + [x0[i] - 0.97 * x0[i - 1] for i in range(1, len(x0))]
        win, hop = rate * 5 // 1000, rate * 2 // 1000
        ws = r["words"]
        for k in range(1, len(ws)):
            prev_end, start = ws[k - 1]["end"], ws[k]["start"]
            if ws[k].get("missing") or start - prev_end < rate // 10:
                continue
            found = []
            for x in (x0, x1):
                gap = [level(x, i, win) for i in range(prev_end, start - win, hop)]
                floor = sorted(gap)[len(gap) // 10] if gap else -90
                thr = max(floor + 15, -50)
                for i in range(prev_end, start + rate * 150 // 1000, hop):
                    if level(x, i, win) >= thr:
                        found.append(i)
                        break
            if not found:
                continue
            onset = min(found)
            d = (start - onset) * 1000 / rate
            diffs.append(d)
            print(f"{jid:16s} {ws[k]['word']:12s} aligned {start / rate:7.3f}s acoustic {onset / rate:7.3f}s Δ {d:+6.1f} ms")
    if not diffs:
        print("no words after a pause")
        return 1
    s = sorted(diffs)
    med = s[len(s) // 2]
    w20 = sum(abs(d) <= 20 for d in s) / len(s)
    w30 = sum(abs(d) <= 30 for d in s) / len(s)
    print(f"n {len(s)}  median Δ {med:+.1f} ms  |Δ| ≤ 20 ms {w20:.0%}  ≤ 30 ms {w30:.0%}  min {s[0]:+.1f} max {s[-1]:+.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
