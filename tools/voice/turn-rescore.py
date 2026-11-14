#!/usr/bin/env python3
"""Re-score a TurnEndTraceTests trace with another end-of-turn model, offline (A-M9-T05-V2b candidate survey).

  python -I tools/voice/turn-rescore.py TRACE FIXTURES OUT --model smart-turn:FILE.onnx | turn-1-mini:FILE.onnx [--level]
  (needs numpy, soundfile, onnxruntime; transformers for smart-turn's WhisperFeatureExtractor)

The audio is prepared exactly like TurnEndTraceTests: speech + noise bed at −20 dB (wrapped) + 40,000 zero samples.
  smart-turn: windows as the detector cuts them (end = last voiced + s ms, from max(turn start, end − 8 s)), reference
              preprocessing (front zero-pad to 8 s, WhisperFeatureExtractor(chunk_length=8), do_normalize).
              v3.2 ONNX against the shipped Core ML trace: median |Δp| 0.0004, 95th pct 0.014 (validates this harness).
  turn-1-mini: the streaming step graph from sample 0 (state zeros); p at s = the last 20 ms frame ending by last
              voiced + s ms.
  --level:    adds `lvl` per pause, the final-energy cue: mean power of the last 6 32-ms frames before the last voiced
              frame minus the median frame level (dB) since the turn start.
The trace's text / sentence / silence_ms are kept; the trace's own smart-turn answers move to `p_ref`.
Replay with tools/voice/turn-replay.py (p) or the frontier in build/at/AT-283/eot-candidates-2026-11-11.json.
"""
import argparse
import json

import numpy as np
import soundfile as sf


def load(path):
    a, sr = sf.read(path, dtype="float32")
    assert sr == 16000, path
    return a if a.ndim == 1 else a.mean(axis=1)


def smart_turn(path):
    import onnxruntime as ort
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor(chunk_length=8)
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    n = 8 * 16000

    def score(w):
        w = w[-n:] if len(w) > n else np.pad(w, (n - len(w), 0))
        x = fe(w, sampling_rate=16000, return_tensors="np", padding="max_length", max_length=n, truncation=True,
               do_normalize=True).input_features.astype(np.float32)
        return float(sess.run(None, {"input_features": x})[0].reshape(-1)[0])
    return score


def turn1mini_stream(path):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    states = ["audio", "conv1", "conv2", "k", "v", "k_valid", "h6"]

    def stream(a):
        st = {i.name: np.zeros(i.shape, np.float32) for i in sess.get_inputs() if i.name != "audio"}
        out, probs = ["probs"] + [f"new_state_{s}" for s in states], []
        for s in range(0, len(a) // 2560 * 2560, 2560):
            p, *new = sess.run(out, {"audio": a[s:s + 2560].reshape(1, 2560).astype(np.float32), **st})
            st = {f"state_{k}": v for k, v in zip(states, new)}
            probs.extend(p.reshape(-1).tolist())
        return np.array(probs)
    return stream


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("fixtures")
    ap.add_argument("out")
    ap.add_argument("--model", required=True)
    ap.add_argument("--level", action="store_true")
    a = ap.parse_args()
    kind, path = a.model.split(":", 1)
    score = smart_turn(path) if kind == "smart-turn" else None
    stream = turn1mini_stream(path) if kind == "turn-1-mini" else None
    tr = json.load(open(a.trace))
    sil = tr["silences_ms"]
    out = {"silences_ms": sil, "model": a.model}
    for bed in ("clean", "cafe", "fan", "keyboard"):
        noise = None if bed == "clean" else load(f"{a.fixtures}/audio/noise/{bed}.wav")
        rows = []
        for row in tr[bed]:
            sub = "turn-split-50" if row["kind"] == "pause" else "dictation"
            x = np.concatenate([load(f"{a.fixtures}/audio/{sub}/{row['file']}"), np.zeros(40000, np.float32)])
            if noise is not None:
                x = x + noise[np.arange(len(x)) % len(noise)] * np.float32(10 ** (-20 / 20))
            probs = stream(x) if stream else None
            nf = len(x) // 512
            pw = (x[: nf * 512].reshape(nf, 512).astype(np.float64) ** 2).mean(axis=1)
            pauses = []
            for pz in row["pauses"]:
                v, start = pz["voiced_ms"] * 16, pz["start_ms"] * 16
                ps = {}
                for s in sil:
                    end = min(len(x), v + s * 16)
                    ps[str(s)] = (score(x[max(start, end - 128000):end]) if score
                                  else float(probs[min(len(probs), end // 320) - 1]))
                q = dict(pz, p=ps, p_ref=pz["p"])
                if a.level:
                    fv, fs = v // 512, start // 512
                    q["lvl"] = float(10 * np.log10(pw[max(fs, fv - 6):fv].mean() + 1e-12)
                                     - np.median(10 * np.log10(pw[fs:fv] + 1e-12)))
                pauses.append(q)
            rows.append({"file": row["file"], "kind": row["kind"], "pauses": pauses})
        out[bed] = rows
    json.dump(out, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
