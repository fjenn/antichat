#!/usr/bin/env python3
"""M3.T15: the voice audio fixtures (environment.md §4) in one entry point. numpy + stdlib; ffmpeg decodes FLAC.

  make-voice-fixtures.py [--fixtures DIR] [--seed 20261030] [--cache DIR] <cmd>
     dictation | fleurs | turn-split | barge-in | long-file | noise | music | all | verify

Output: 16 kHz mono 16-bit PCM WAV everywhere except music/ (44.1 kHz stereo). Every folder gets SOURCES.md and
manifest.json. Sources (CC BY 4.0, anonymous, sha256/md5 recorded):
  * LibriSpeech test-clean, https://www.openslr.org/resources/12/test-clean.tar.gz (md5 32fa31d2…, as M0.T05).
    All selections exclude the 200 utterances of librispeech-test-clean-200 and never reuse an utterance across
    folders; pools are walked in sorted-id order, so the same archive gives the same files.
  * FLEURS, HF dataset google/fleurs @ FLEURS_SHA, configs de_de ja_jp cmn_hans_cn ar_eg, split test: the first
    40 distinct sentence ids in archive order (the archive is streamed and the download stops after 40, instead
    of fetching ~1.8 GB to sort by id; deterministic for the pinned commit).
Synthetic content (silence, cough, noise beds, music, RIRs, pause lengths, barge-in onsets) comes from
numpy.random.default_rng(seed + <fixed offset per use>), so re-running reproduces identical bytes.
The barge-in TTS stems are Kokoro (`tts`, voice af_heart) via the gated Swift test BargeInStemSynthesisTests, run
through the lead's `gpu-run.sh shared` (accuracy-only model run; override the path with $GPU_RUN).

Run with tools/.venv/bin/python3 -I (needs numpy).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SR = 16_000
LIBRI_URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
LIBRI_MD5 = "32fa31d27d2e1cad72775fee3f4849a9"
FLEURS_SHA = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
FLEURS = {"de": "de_de", "ja": "ja_jp", "zh": "cmn_hans_cn", "ar": "ar_eg"}
N_FLEURS = 40
ROOMS = [0.3, 0.5, 0.8]  # RT60 seconds
TTS_TEXTS = ROOT / "tools/fixtures/barge-in-texts.txt"
SYNTHETIC = ["noise", "music"]  # + dictation silence-5s / cough (checked separately)

# ---------------------------------------------------------------- audio helpers


def dbfs_rms(x: np.ndarray) -> float:
    r = float(np.sqrt(np.mean(np.square(x, dtype=np.float64)))) if len(x) else 0.0
    return 20 * np.log10(r) if r > 0 else -np.inf


def at_rms(x: np.ndarray, db: float) -> np.ndarray:
    cur = dbfs_rms(x)
    return x * (10 ** ((db - cur) / 20)) if np.isfinite(cur) else x


def to_i16(x: np.ndarray) -> bytes:
    return (np.clip(x, -1, 1) * 32767).round().astype("<i2").tobytes()


def write_wav(path: Path, x: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ch = 1 if x.ndim == 1 else x.shape[1]
    with wave.open(str(path), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(to_i16(x.reshape(-1)))


def read_wav(path: Path) -> tuple[np.ndarray, int, int]:
    with wave.open(str(path), "rb") as w:
        sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        assert sw == 2, f"{path}: not 16-bit"
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32767
    return (x.reshape(-1, ch) if ch > 1 else x), sr, ch


def decode(data: bytes, sr: int = SR) -> np.ndarray:
    """Any container (FLAC, WAV…) → mono float32 at `sr` through ffmpeg (stdin → stdout, no temp files)."""
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", str(sr), "pipe:1"],
                       input=data, capture_output=True, check=True)
    return np.frombuffer(p.stdout, dtype="<i2").astype(np.float32) / 32767


def silence(n: int, rng: np.random.Generator, db: float = -70.0) -> np.ndarray:
    """Near-silence (white noise at `db` dBFS) instead of digital zeros."""
    return at_rms(rng.standard_normal(n).astype(np.float32), db) if n > 0 else np.zeros(0, np.float32)


def pink(n: int, rng: np.random.Generator) -> np.ndarray:
    f = np.fft.rfftfreq(n, 1 / SR)
    spec = rng.standard_normal(len(f)) + 1j * rng.standard_normal(len(f))
    spec[1:] /= np.sqrt(f[1:])
    spec[0] = 0
    return np.fft.irfft(spec, n).astype(np.float32)


def bandpass(x: np.ndarray, lo: float, hi: float, sr: int = SR) -> np.ndarray:
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / sr)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, len(x)).astype(np.float32)


def fftconv(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    n = len(x) + len(h) - 1
    m = 1 << (n - 1).bit_length()
    return np.fft.irfft(np.fft.rfft(x, m) * np.fft.rfft(h, m), m)[:n].astype(np.float32)


def rir(rt60: float, rng: np.random.Generator) -> np.ndarray:
    """Synthetic room impulse response: direct path + exponentially decaying noise tail (−60 dB at rt60)."""
    n = int(rt60 * 1.2 * SR)
    t = np.arange(n) / SR
    h = rng.standard_normal(n) * np.exp(-6.908 * t / rt60) * 0.3
    h[:int(0.002 * SR)] = 0  # 2 ms before the first reflection
    h[0] = 1.0
    return (h / np.sqrt(np.sum(h ** 2))).astype(np.float32)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fmt_ts(s: float) -> str:
    s = int(s)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def write_manifest(folder: Path, items: list[dict], extra: dict | None = None) -> None:
    doc = {"generator": "tools/fixtures/make-voice-fixtures.py", **(extra or {}), "items": items}
    (folder / "manifest.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def write_sources(folder: Path, title: str, body: str) -> None:
    (folder / "SOURCES.md").write_text(
        f"# audio/{folder.name if folder.parent.name == 'audio' else folder.parent.name + '/' + folder.name} — sources\n\n"
        f"{title}\n\n{body.strip()}\n\n"
        "- Generator: `tools/fixtures/make-voice-fixtures.py` (app repo, M3.T15), seed 20261030; "
        "`make-voice-fixtures.py verify` checks counts, formats, durations and manifests.\n"
        "- Rule: no real personal data beyond the volunteer readers' public recordings; no sexual content of any kind.\n",
        encoding="utf-8")


# ---------------------------------------------------------------- LibriSpeech pools


def fetch(url: str, dest: Path) -> Path:
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    subprocess.run(["curl", "-sSfL", "-C", "-", "-o", str(part), url], check=True)
    part.rename(dest)
    return dest


class Libri:
    def __init__(self, cache: Path, fixtures: Path):
        tar = fetch(LIBRI_URL, cache / "test-clean.tar.gz")
        h = hashlib.md5()
        with open(tar, "rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        if h.hexdigest() != LIBRI_MD5:
            sys.exit(f"test-clean.tar.gz md5 {h.hexdigest()} != {LIBRI_MD5}")
        self.text: dict[str, str] = {}
        self.flac: dict[str, bytes] = {}
        with tarfile.open(tar, "r:gz") as t:
            for m in t:
                if m.name.endswith(".trans.txt"):
                    for line in t.extractfile(m).read().decode().splitlines():
                        uid, _, text = line.partition(" ")
                        self.text[uid] = text
                elif m.name.endswith(".flac"):
                    self.flac[os.path.basename(m.name)[:-5]] = t.extractfile(m).read()
        sub = fixtures / "audio/librispeech-test-clean-200/transcripts.tsv"
        self.excluded = {l.split("\t")[0] for l in sub.read_text().splitlines() if l and not l.startswith("id\t")}
        assert len(self.excluded) == 200, f"{sub}: {len(self.excluded)} ids"
        self.ids = sorted(i for i in self.text if i not in self.excluded)
        self.dur = {i: self._duration(self.flac[i]) for i in self.ids}
        self.plan = self._plan()

    @staticmethod
    def _duration(data: bytes) -> float:
        si = data[8:8 + 34]
        rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4)
        total = ((si[13] & 0x0F) << 32) | (si[14] << 24) | (si[15] << 16) | (si[16] << 8) | si[17]
        return total / rate

    def audio(self, uid: str) -> np.ndarray:
        return decode(self.flac[uid])

    def _plan(self) -> dict[str, list[str]]:
        """Every folder's utterances, in one fixed pass so each subcommand sees the same split."""
        used: set[str] = set()

        def take(pred, n: int) -> list[str]:
            out = [i for i in self.ids if i not in used and pred(self.dur[i])][:n]
            used.update(out)
            return out

        plan = {"dictation": take(lambda d: 2 <= d <= 8, 27)}
        # Monologue: consecutive utterances of one speaker-chapter, 0.3 s gaps, 28–30 s.
        groups: dict[str, list[str]] = {}
        for i in self.ids:
            if i not in used:
                groups.setdefault(i.rsplit("-", 1)[0], []).append(i)
        for g in sorted(groups):
            seq, total = [], 0.0
            for i in groups[g]:
                add = self.dur[i] + (0.3 if seq else 0)
                if total + add > 30:
                    break
                seq.append(i)
                total += add
                if total >= 28:
                    break
            if 28 <= total <= 30:
                plan["monologue"] = seq
                used.update(seq)
                break
        plan["turn-split"] = take(lambda d: d >= 6, 50)
        plan["barge-in"] = take(lambda d: 2 <= d <= 5, 12)
        plan["cafe"] = take(lambda d: d >= 4, 8)
        seq, total = [], 0.0
        for i in self.ids:
            if i in used:
                continue
            add = self.dur[i] + (0.5 if seq else 0)
            if total + add > 3605:
                continue
            seq.append(i)
            total += add
            if total >= 3595:
                break
        plan["long-file"] = seq
        used.update(seq)
        return plan


# ---------------------------------------------------------------- folders


def make_dictation(fx: Path, lib: Libri, seed: int) -> None:
    out = fx / "audio/dictation"
    items = []
    for k, uid in enumerate(lib.plan["dictation"], 1):
        name = f"q{k:02d}"
        write_wav(out / f"{name}.wav", lib.audio(uid))
        (out / f"{name}.txt").write_text(lib.text[uid] + "\n")
        items.append({"file": f"{name}.wav", "source": uid, "duration_s": round(lib.dur[uid], 3), "text": lib.text[uid]})
    rng = np.random.default_rng(seed + 1)
    parts, texts = [], []
    for j, uid in enumerate(lib.plan["monologue"]):
        if j:
            parts.append(silence(int(0.3 * SR), rng))
        parts.append(lib.audio(uid))
        texts.append(lib.text[uid])
    mono = np.concatenate(parts)
    write_wav(out / "monologue-30s.wav", mono)
    (out / "monologue-30s.txt").write_text(" ".join(texts) + "\n")
    items.append({"file": "monologue-30s.wav", "source": lib.plan["monologue"], "duration_s": round(len(mono) / SR, 3),
                  "text": " ".join(texts)})
    for name, x in synthetic_dictation(seed).items():
        write_wav(out / f"{name}.wav", x)
        (out / f"{name}.txt").write_text("")
        items.append({"file": f"{name}.wav", "source": "synthetic", "duration_s": round(len(x) / SR, 3), "text": ""})
    write_manifest(out, items)
    write_sources(out, "Purpose: dictation (R-050, NFR-V5…V7, V10): 27 short utterances, a 30 s monologue, silence-only "
                  "and a non-speech burst (environment.md §4).", f"""
- `q01…q27.wav` + `.txt`: the first 27 LibriSpeech test-clean utterances (sorted id) of 2–8 s that are not in
  `librispeech-test-clean-200`; transcript = the uppercase LibriSpeech reference. Origin {LIBRI_URL} (md5 {LIBRI_MD5}),
  CC BY 4.0 (Panayotov et al., ICASSP 2015; LibriVox public-domain audio).
- `monologue-30s.wav`: consecutive utterances of one speaker-chapter joined with 0.3 s near-silence (−70 dBFS), 28–30 s.
- `silence-5s.wav`: 5 s pink noise at −65 dBFS RMS (synthetic, seeded); empty transcript.
- `cough.wav`: [ASSUMPTION] two synthetic non-speech bursts (noise band-passed 200–2000 Hz, 250 ms each, 400 ms
  apart, 0.5 s padding) standing in for a recorded cough; empty transcript.""")


def synthetic_dictation(seed: int) -> dict[str, np.ndarray]:
    rng = np.random.default_rng(seed + 2)
    sil = at_rms(pink(5 * SR, rng), -65)
    rng = np.random.default_rng(seed + 3)
    burst = lambda: bandpass(rng.standard_normal(int(0.25 * SR)).astype(np.float32), 200, 2000) * np.hanning(int(0.25 * SR))
    pad = lambda s: silence(int(s * SR), rng)
    cough = np.concatenate([pad(0.5), at_rms(burst(), -18), pad(0.4), at_rms(burst(), -20), pad(0.5)])
    return {"silence-5s": sil.astype(np.float32), "cough": cough.astype(np.float32)}


def make_turn_split(fx: Path, lib: Libri, seed: int) -> None:
    out = fx / "audio/turn-split-50"
    rng = np.random.default_rng(seed + 10)
    items = []
    fr = int(0.02 * SR)
    for k, uid in enumerate(lib.plan["turn-split"], 1):
        x = lib.audio(uid)
        n = len(x) // fr
        e = np.array([dbfs_rms(x[i * fr:(i + 1) * fr]) for i in range(n)])
        lo, hi, mid = int(0.3 * n), int(0.7 * n), n / 2
        low = [i for i in range(lo, hi) if e[i] < -40]
        runs, cur = [], []
        for i in low:
            if cur and i != cur[-1] + 1:
                runs.append(cur)
                cur = []
            cur.append(i)
        if cur:
            runs.append(cur)
        if runs:
            best = min(runs, key=lambda r: abs((r[0] + r[-1]) / 2 - mid))
        else:  # no frame under −40 dBFS in the span: the quietest frame
            best = [lo + int(np.argmin(e[lo:hi]))]
        a, b = best[0] * fr, (best[-1] + 1) * fr
        pause = float(rng.uniform(0.3, 1.2))
        gap = silence(int(pause * SR), rng)
        y = np.concatenate([x[:a], gap, x[b:], silence(2 * SR, rng)])
        name = f"{k:02d}.wav"
        write_wav(out / name, y)
        (out / f"{k:02d}.txt").write_text(lib.text[uid] + "\n")
        items.append({"file": name, "source": uid, "pause_ms": round(pause * 1000), "pause_at_ms": round(a / SR * 1000),
                      "expected_turns": 1, "text": lib.text[uid]})
    write_manifest(out, items)
    write_sources(out, "Purpose: false turn splits (R-283, NFR-V4): one turn with a mid-utterance pause.", f"""
- 50 LibriSpeech test-clean utterances of ≥ 6 s (sorted id; not in the 200 subset or `dictation/`). Origin {LIBRI_URL},
  CC BY 4.0.
- Method: 20 ms frames; the low-energy run (< −40 dBFS) closest to the midpoint within 30–70 % of the utterance is
  replaced by a near-silent pause of U(0.3, 1.2) s (seeded); 2 s trailing near-silence. `manifest.json`:
  `{{file, pause_ms, pause_at_ms, expected_turns: 1}}`.""")


def make_barge_in(fx: Path, lib: Libri, seed: int, cache: Path, swift_models: str | None) -> None:
    out = fx / "audio/barge-in"
    texts = [l.strip() for l in TTS_TEXTS.read_text().splitlines() if l.strip() and not l.startswith("#")]
    assert len(texts) == 12
    stems = cache / "barge-in-tts"
    if not all((stems / f"tts{k:02d}.wav").exists() for k in range(1, 13)):
        env = dict(os.environ, ANTICHAT_SYNTH_OUT=str(stems), ANTICHAT_SYNTH_TEXTS=str(TTS_TEXTS))
        if swift_models:
            env["ANTICHAT_MODELS"] = swift_models
        subprocess.run([os.environ.get("GPU_RUN", "/Users/armando/AntiChat-tools/gpu-run.sh"), "shared", "--", "swift", "test", "--disable-keychain", "--filter",
                        "BargeInStemSynthesisTests"], cwd=ROOT, env=env, check=True)
    items = []
    for k, uid in enumerate(lib.plan["barge-in"], 1):
        tts = decode((stems / f"tts{k:02d}.wav").read_bytes())
        user = lib.audio(uid)
        for r, rt in enumerate(ROOMS, 1):
            rng = np.random.default_rng(seed + 100 + k * 10 + r)
            h_tts, h_user = rir(rt, rng), rir(rt, rng)
            onset = int(rng.integers(800, 3001))
            n = max(len(tts), onset * SR // 1000 + len(user)) + int(0.5 * SR) + len(h_tts)
            echo = np.zeros(n, np.float32)
            e = fftconv(tts, h_tts)
            echo[:len(e)] = e
            near = np.zeros(n, np.float32)
            u = fftconv(user, h_user)
            o = onset * SR // 1000
            near[o:o + len(u)] = u
            # Speech-to-echo ratio 0 dB: equal RMS over each signal's own active span.
            near *= 10 ** ((dbfs_rms(echo[:len(e)]) - dbfs_rms(u)) / 20)
            peak = max(np.max(np.abs(echo + near)), 1e-9)
            g = min(1.0, 0.89 / peak)  # ≤ −1 dBFS
            base = f"item{k:02d}-room{r}"
            write_wav(out / f"{base}-user.wav", near * g)
            write_wav(out / f"{base}-tts.wav", echo * g)
            write_wav(out / f"{base}-mic.wav", (echo + near) * g)
            items.append({"item": k, "room": r, "rt60_s": rt, "onset_ms": onset, "tts_text": texts[k - 1],
                          "user_source": uid, "user_text": lib.text[uid]})
    write_manifest(out, items, {"speech_to_echo_db": 0, "rooms_rt60_s": ROOMS})
    write_sources(out, "Purpose: barge-in and spoken-span truncation (R-282, NFR-V3; M3.T10/T12): 12 items × 3 rooms.", f"""
- `tts` stems: the 12 sentences of `tools/fixtures/barge-in-texts.txt` (written for this task), synthesised offline with
  Kokoro-82M (`tts` = FluidInference/kokoro-82m-coreml@2568276, Apache-2.0, voice af_heart) by the gated Swift test
  `BargeInStemSynthesisTests`, resampled to 16 kHz.
- `user` stems: 12 LibriSpeech test-clean utterances of 2–5 s (sorted id, unused elsewhere). Origin {LIBRI_URL}, CC BY 4.0.
- Rooms: synthetic RIRs (direct path + exponential-decay noise), RT60 0.3 / 0.5 / 0.8 s, seeded. `-tts` = TTS ⊛ RIR,
  `-user` = user ⊛ RIR starting `onset_ms` ∈ [800, 3000] after TTS start, `-mic` = both at 0 dB speech-to-echo ratio
  (one shared gain keeps peaks ≤ −1 dBFS). `manifest.json`: `{{item, room, onset_ms, tts_text}}` + sources.""")


def make_long_file(fx: Path, lib: Libri, seed: int) -> None:
    out = fx / "audio/long-file"
    rng = np.random.default_rng(seed + 20)
    parts, lines, t = [], [], 0.0
    for j, uid in enumerate(lib.plan["long-file"]):
        if j:
            parts.append(silence(int(0.5 * SR), rng))
            t += 0.5
        x = lib.audio(uid)
        lines.append(f"[{fmt_ts(t)}] {lib.text[uid]}")
        parts.append(x)
        t += len(x) / SR
    y = np.concatenate(parts)
    write_wav(out / "long-60min.wav", y)
    (out / "long-60min.txt").write_text("\n".join(lines) + "\n")
    write_manifest(out, [{"file": "long-60min.wav", "duration_s": round(len(y) / SR, 3), "utterances": len(lines),
                          "sources": lib.plan["long-file"]}])
    write_sources(out, "Purpose: long-file transcription (R-056, NFR-V11; M3.T06).", f"""
- `long-60min.wav`: {len(lines)} LibriSpeech test-clean utterances (sorted id, unused by every other folder) joined with
  0.5 s near-silence to 60:00 ± 5 s; `long-60min.txt` has `[hh:mm:ss] text` per utterance (ground truth). Origin
  {LIBRI_URL}, CC BY 4.0. Environment §4 asks for a Kokoro-generated script; real speech is used so the transcript
  is ground truth (amendment A-M3-05, minor).""")


def synthetic_noise(seed: int, lib: Libri | None) -> dict[str, np.ndarray]:
    n = 60 * SR
    t = np.arange(n) / SR
    out = {}
    rng = np.random.default_rng(seed + 30)
    brown = np.cumsum(rng.standard_normal(n)).astype(np.float64)
    brown -= np.convolve(brown, np.ones(SR) / SR, mode="same")  # remove the random-walk drift
    hum = 0.3 * np.sin(2 * np.pi * 120 * t) + 0.1 * np.sin(2 * np.pi * 240 * t)
    out["fan"] = at_rms(at_rms(brown.astype(np.float32), -30) + at_rms(hum.astype(np.float32), -38), -30)
    rng = np.random.default_rng(seed + 31)
    keys = np.zeros(n, np.float32)
    pos = 0.0
    while True:
        pos += 1 / rng.uniform(5, 8)
        i = int(pos * SR)
        if i >= n - 400:
            break
        click = rng.standard_normal(240).astype(np.float32) * np.exp(-np.arange(240) / 30)
        keys[i:i + 240] += bandpass(click, 1000, 6000) * rng.uniform(0.5, 1.0)
    out["keyboard"] = at_rms(keys + silence(n, rng, -60), -30)
    if lib is not None:
        rng = np.random.default_rng(seed + 32)
        cafe = np.zeros(n, np.float32)
        for uid in lib.plan["cafe"]:
            x = lib.audio(uid)
            for _ in range(int(np.ceil(n / len(x))) + 1):  # each voice loops at a random offset
                o = int(rng.integers(0, n))
                seg = x[: n - o]
                cafe[o:o + len(seg)] += seg * rng.uniform(0.4, 1.0)
        for _ in range(40):  # cup / cutlery clatter
            i = int(rng.integers(0, n - 2000))
            cafe[i:i + 2000] += bandpass(rng.standard_normal(2000).astype(np.float32), 2000, 7000) * np.exp(-np.arange(2000) / 300) * 2
        out["cafe"] = at_rms(cafe, -30)
    return out


def make_noise(fx: Path, lib: Libri, seed: int) -> None:
    out = fx / "audio/noise"
    items = []
    for name, x in synthetic_noise(seed, lib).items():
        write_wav(out / f"{name}.wav", x)
        items.append({"file": f"{name}.wav", "duration_s": 60, "rms_dbfs": -30})
    items.sort(key=lambda d: d["file"])
    write_manifest(out, items)
    write_sources(out, "Purpose: noise beds mixed at −20 dB for NFR-V4 / barge-in robustness (M3.T09/T12).", f"""
- All synthetic (seeded), 60 s, 16 kHz mono, −30 dBFS RMS: `fan.wav` brown noise + 120/240 Hz hum; `keyboard.wav`
  band-passed clicks at 5–8 Hz; `cafe.wav` babble of 8 LibriSpeech test-clean voices looped at random offsets
  (CC BY 4.0, {LIBRI_URL}; sorted id, unused elsewhere) plus clatter impulses.""")


def synthetic_music(seed: int) -> np.ndarray:
    sr = 44_100
    chords = [[261.63, 329.63, 392.00], [220.00, 261.63, 329.63], [174.61, 220.00, 261.63], [196.00, 246.94, 293.66]]
    seg = 2 * sr
    t = np.arange(seg) / sr
    env = np.minimum(1, np.minimum(t / 0.05, (2 - t) / 0.3))
    rng = np.random.default_rng(seed + 40)
    left, right = [], []
    for k in range(30):
        c = chords[k % 4]
        s = sum(sum(np.sin(2 * np.pi * f * h * t) / h ** 1.5 for h in (1, 2, 3, 4)) for f in c) * env
        pan = 0.5 + 0.2 * np.sin(k)
        left.append(s * (1 - pan) + rng.standard_normal(seg) * 1e-4)
        right.append(s * pan + rng.standard_normal(seg) * 1e-4)
    x = np.stack([np.concatenate(left), np.concatenate(right)], axis=1).astype(np.float32)
    return at_rms(x, -20)


def make_music(fx: Path, seed: int) -> None:
    out = fx / "audio/music"
    write_wav(out / "bed-60s.wav", synthetic_music(seed), 44_100)
    write_manifest(out, [{"file": "bed-60s.wav", "duration_s": 60, "sample_rate": 44100, "channels": 2, "rms_dbfs": -20}])
    write_sources(out, "Purpose: music bed for the ducking checks (M3.T12 AC3, vq-08 step 23).", """
- `bed-60s.wav`: synthetic I–vi–IV–V chord progression (sines + 4 harmonics, 2 s per chord), 44.1 kHz stereo,
  −20 dBFS RMS, seeded. No music library or account needed.""")


def make_fleurs(fx: Path, cache: Path) -> None:
    for short, cfg in FLEURS.items():
        out = fx / f"audio/fleurs-multi/{short}"
        base = f"https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_SHA}/data/{cfg}"
        tsv = fetch(f"{base}/test.tsv", cache / f"fleurs/{cfg}-test.tsv")
        rows = {}
        for line in tsv.read_text(encoding="utf-8").splitlines():
            c = line.split("\t")
            rows[c[1]] = (c[0], c[2])  # file → (sentence id, raw_transcription)
        items, seen = [], set()
        req = urllib.request.Request(f"{base}/audio/test.tar.gz", headers={"User-Agent": "antichat-fixtures"})
        with urllib.request.urlopen(req) as resp, tarfile.open(fileobj=resp, mode="r|gz") as t:
            for m in t:
                fn = os.path.basename(m.name)
                if not m.isfile() or fn not in rows or rows[fn][0] in seen:
                    continue
                sid, text = rows[fn]
                seen.add(sid)
                k = len(items) + 1
                write_wav(out / f"{k:02d}.wav", decode(t.extractfile(m).read()))
                (out / f"{k:02d}.txt").write_text(text + "\n", encoding="utf-8")
                items.append({"file": f"{k:02d}.wav", "source": fn, "sentence_id": sid, "text": text})
                if len(items) == N_FLEURS:
                    break  # stop streaming: the rest of the archive is never downloaded
        assert len(items) == N_FLEURS, f"{cfg}: {len(items)} items"
        write_manifest(out, items, {"dataset": f"google/fleurs@{FLEURS_SHA}", "config": cfg, "split": "test"})
        write_sources(out, f"Purpose: STT language routing and accuracy (R-284, NFR-V9; M3.T05) — {cfg}.", f"""
- Origin: HF dataset `google/fleurs` at commit `{FLEURS_SHA}` (resolved via `GET https://huggingface.co/api/datasets/google/fleurs`,
  2026-11-04), `data/{cfg}/audio/test.tar.gz` + `test.tsv`; ungated; licence CC BY 4.0 (Conneau et al., "FLEURS", 2022).
- Selection: the first {N_FLEURS} distinct sentence ids in archive order (streamed; the download stops after item {N_FLEURS}).
  M3.md asks for the first 40 sorted by id, which needs the whole ~0.25–0.57 GB archive per language; archive order is
  equally deterministic for the pinned commit (minor deviation, A-M3-T15a).
- `NN.wav` 16 kHz mono 16-bit (ffmpeg), `NN.txt` = `raw_transcription`.""")


# ---------------------------------------------------------------- verify


def verify(fx: Path, seed: int) -> int:
    a = fx / "audio"
    bad: list[str] = []

    def check_folder(rel: str, n_wav: int, sr: int = SR, ch: int = 1) -> list[Path]:
        d = a / rel
        wavs = sorted(d.glob("*.wav"))
        if len(wavs) != n_wav:
            bad.append(f"{rel}: {len(wavs)} wav, want {n_wav}")
        for w in wavs:
            with wave.open(str(w), "rb") as f:
                if (f.getframerate(), f.getnchannels(), f.getsampwidth()) != (sr, ch, 2):
                    bad.append(f"{w.relative_to(a)}: {f.getframerate()} Hz × {f.getnchannels()} ch × {8 * f.getsampwidth()} bit")
        for req in ("SOURCES.md", "manifest.json"):
            if not (d / req).exists():
                bad.append(f"{rel}: no {req}")
        try:
            json.loads((d / "manifest.json").read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            bad.append(f"{rel}/manifest.json: {e}")
        return wavs

    def dur(p: Path) -> float:
        with wave.open(str(p), "rb") as f:
            return f.getnframes() / f.getframerate()

    def txt_ok(wavs: list[Path], empty: set[str] = set()) -> None:
        for w in wavs:
            t = w.with_suffix(".txt")
            if not t.exists():
                bad.append(f"{t.relative_to(a)} missing")
            elif (t.read_text().strip() == "") != (w.stem in empty):
                bad.append(f"{t.relative_to(a)}: {'empty' if w.stem not in empty else 'not empty'}")

    w = check_folder("dictation", 30)
    txt_ok(w, {"silence-5s", "cough"})
    m = a / "dictation/monologue-30s.wav"
    if m.exists() and not 28 <= dur(m) <= 30:
        bad.append(f"monologue {dur(m):.1f} s")
    for lang in FLEURS:
        txt_ok(check_folder(f"fleurs-multi/{lang}", N_FLEURS))
    w = check_folder("turn-split-50", 50)
    txt_ok(w)
    check_folder("barge-in", 36 * 3)
    lf = check_folder("long-file", 1)
    if lf and not 3595 <= dur(lf[0]) <= 3605:
        bad.append(f"long-file {dur(lf[0]):.1f} s")
    if lf and not (a / "long-file/long-60min.txt").read_text().strip():
        bad.append("long-60min.txt empty")
    check_folder("noise", 3)
    check_folder("music", 1, 44_100, 2)
    # Reproducibility of the synthetic files: regenerate in memory and compare bytes.
    regen = {**{f"dictation/{k}.wav": (v, SR) for k, v in synthetic_dictation(seed).items()},
             **{f"noise/{k}.wav": (v, SR) for k, v in synthetic_noise(seed, None).items()},
             "music/bed-60s.wav": (synthetic_music(seed), 44_100)}
    with tempfile.TemporaryDirectory() as tmp:
        for rel, (x, sr) in regen.items():
            p = Path(tmp) / rel.replace("/", "_")
            write_wav(p, x, sr)
            if (a / rel).exists() and sha256(p) != sha256(a / rel):
                bad.append(f"{rel}: not reproduced by seed {seed}")
    for b in bad:
        print(f"[fail] {b}")
    print(f"verify: {'ok' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["dictation", "fleurs", "turn-split", "barge-in", "long-file", "noise", "music", "all", "verify"])
    ap.add_argument("--fixtures", default=os.environ.get("ANTICHAT_FIXTURES", str(ROOT / "fixtures")))
    ap.add_argument("--seed", type=int, default=20261030)
    ap.add_argument("--cache", default=str(Path.home() / "Library/Caches/AntiChat-Dev/datasets"))
    ap.add_argument("--models", default=None, help="dev model store for the Kokoro stems (default: AntiChat-Dev/Models)")
    a = ap.parse_args()
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg not found")
    fx, cache = Path(a.fixtures), Path(a.cache)
    if a.cmd == "verify":
        return verify(fx, a.seed)
    if a.cmd == "music":
        make_music(fx, a.seed)
        return 0
    if a.cmd == "fleurs":
        make_fleurs(fx, cache)
        return 0
    lib = Libri(cache, fx)
    steps = {"dictation": lambda: make_dictation(fx, lib, a.seed), "turn-split": lambda: make_turn_split(fx, lib, a.seed),
             "barge-in": lambda: make_barge_in(fx, lib, a.seed, cache, a.models),
             "long-file": lambda: make_long_file(fx, lib, a.seed), "noise": lambda: make_noise(fx, lib, a.seed)}
    if a.cmd == "all":
        for s in steps.values():
            s()
        make_music(fx, a.seed)
        make_fleurs(fx, cache)
    else:
        steps[a.cmd]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
