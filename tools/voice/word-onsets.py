#!/usr/bin/env python3
"""Acoustic word onsets of known text in audio, by forced alignment (AT-282 AC2 reference, A-M9-T05-AT282b).

  tools/voice/word-onsets.py JOBS.json OUT.json [--mfa PATH]      (python3 -I; stdlib + the MFA environment)

JOBS.json: [{"id": str, "wav": path (any rate, mono), "text": the words that were synthesised}]
OUT.json:  {id: {"sample_rate": rate of the wav, "words": [{"word", "start", "end"}]}} — one entry per word of `text`
           as `BargeInFixtureTests.words` splits it (lowercased, split on anything but letters, digits and '), in
           order; start/end in samples of the input wav. A word MFA could not place gets the end of the previous
           word as both start and end (never early) and "missing": true.

The aligner is the Montreal Forced Aligner 3.4.3 (MIT; conda-forge) with the `english_us_arpa` acoustic model 3.0.0,
dictionary 3.0.0 and G2P model 2.0.0a (CC BY 4.0; acoustic model trained on LibriSpeech). It is an HMM-GMM aligner that models silence explicitly:
word boundaries 19.9 ms mean / 66.5 % ≤ 25 ms on TIMIT (McAuliffe et al. 2026, arXiv 2606.18466, Table 4), against
43 ms for MMS CTC and 110 ms for WhisperX. CTC aligners (and ASR emission times: Parakeet TDT word "starts" are the
previous token's end) put a word's start late or early by tens of ms, which is what AT-282 cannot use. Independent of
the synthesiser: Kokoro's own durations are never read.

Install (once; idempotent, versions and sha256 pinned): tools/voice/setup-mfa.sh — also `make mfa` and
tools/bootstrap.sh step 11b. ANTICHAT_MFA overrides the mfa executable (default ~/.local/share/mfa/bin/mfa).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave

MFA = os.path.expanduser("~/.local/share/mfa/bin/mfa")
SPELLED = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty".split()


def words(text: str) -> list[str]:
    """`BargeInFixtureTests.words`: lowercased, split on anything that is not a letter, digit or apostrophe."""
    return [w for w in re.split(r"[^\w']|_", text.lower().replace("’", "'")) if w]


def spoken(word: str) -> list[str]:
    """What the synthesiser says for one word (numbers up to twenty spelled; others digit by digit)."""
    w = word.strip("'")
    if w.isdigit():
        n = int(w)
        return [SPELLED[n]] if n < len(SPELLED) else [SPELLED[int(c)] for c in w]
    return [w] if w else []


def rate_of(path: str) -> int:
    with wave.open(path) as f:
        assert f.getnchannels() == 1, path
        return f.getframerate()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("jobs")
    ap.add_argument("out")
    ap.add_argument("--mfa", default=os.environ.get("ANTICHAT_MFA", MFA))
    a = ap.parse_args()
    if not os.path.exists(a.mfa):
        print(f"word-onsets: MFA not found at {a.mfa} (see the install note in this file)", file=sys.stderr)
        return 2
    jobs = json.load(open(a.jobs))
    out: dict = {}
    with tempfile.TemporaryDirectory() as tmp:
        corpus, aligned = os.path.join(tmp, "corpus"), os.path.join(tmp, "aligned")
        os.makedirs(corpus)
        rates, plan = {}, {}
        for j in jobs:
            stem = re.sub(r"[^A-Za-z0-9_-]", "_", j["id"])
            rates[j["id"]] = rate_of(j["wav"])  # MFA resamples itself (24 kHz and 16 kHz give identical boundaries)
            shutil.copy(j["wav"], os.path.join(corpus, stem + ".wav"))
            plan[j["id"]] = (stem, [(w, spoken(w)) for w in words(j["text"])])
            with open(os.path.join(corpus, stem + ".lab"), "w") as f:
                f.write(" ".join(s for _, ss in plan[j["id"]][1] for s in ss))
        cmd = [a.mfa, "align", "--clean", "--quiet", "--output_format", "json", "--g2p_model_path", "english_us_arpa",
               "--temporary_directory", os.path.join(tmp, "mfa"),
               corpus, "english_us_arpa", "english_us_arpa", aligned]
        env = dict(os.environ, PATH=os.path.dirname(a.mfa) + os.pathsep + os.environ.get("PATH", ""))  # kaldi/openfst
        r = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stdout[-2000:], r.stderr[-4000:], file=sys.stderr)
            return r.returncode
        for jid, (stem, plan_words) in plan.items():
            path = os.path.join(aligned, stem + ".json")
            entries = []
            if os.path.exists(path):
                doc = json.load(open(path))
                entries = [(s, e, w.lower()) for s, e, w in doc["tiers"]["words"]["entries"] if w and w not in ("<eps>", "sil", "sp", "spn")]
            rate = rates[jid]
            res, k, prev_end = [], 0, 0
            for word, ss in plan_words:
                # the reply word starts where its first spoken word starts
                first, last, missing = None, None, False
                for s in ss:
                    if k < len(entries) and entries[k][2] == s:
                        first = entries[k][0] if first is None else first
                        last = entries[k][1]
                        k += 1
                    else:
                        missing = True
                if first is None:
                    first = last = prev_end / rate
                    missing = True
                prev_end = int(round(last * rate))
                row = {"word": word, "start": int(round(first * rate)), "end": prev_end}
                if missing:
                    row["missing"] = True
                res.append(row)
            out[jid] = {"sample_rate": rate, "words": res, "aligned": len(entries)}
    json.dump(out, open(a.out, "w"), indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
