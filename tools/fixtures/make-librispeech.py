#!/usr/bin/env python3
"""Build fixtures/audio/librispeech-test-clean-200 (M0.T05 inputs; NFR-V1 bench, NFR-V9 later). Stdlib only.

1. Verify the archive against OpenSLR's published md5 (https://www.openslr.org/resources/12/md5sum.txt:
   test-clean.tar.gz 32fa31d27d2e1cad72775fee3f4849a9).
2. Read every `*.trans.txt`, sort the utterance IDs lexicographically and keep the first 200.
3. Copy those FLAC files unchanged to <out>/<id>.flac and write <out>/transcripts.tsv
   (`id \t duration_s \t transcript`; duration from the FLAC STREAMINFO block) and SOURCES.md.

Usage: python3 -I tools/fixtures/make-librispeech.py --tar build/t05-dl/test-clean.tar.gz \
           --out fixtures/audio/librispeech-test-clean-200
"""
from __future__ import annotations

import argparse
import hashlib
import os
import tarfile

MD5 = "32fa31d27d2e1cad72775fee3f4849a9"
URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
N = 200


def flac_duration(data: bytes) -> float:
    assert data[:4] == b"fLaC", "not a FLAC file"
    # First metadata block must be STREAMINFO (type 0), 34 bytes.
    si = data[8:8 + 34]
    rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4)
    total = ((si[13] & 0x0F) << 32) | (si[14] << 24) | (si[15] << 16) | (si[16] << 8) | si[17]
    return total / rate


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tar", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    h = hashlib.md5()
    with open(a.tar, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != MD5:
        print(f"md5 mismatch: {h.hexdigest()} != {MD5}")
        return 20
    print(f"[ok] md5 {MD5}")
    texts: dict[str, str] = {}
    flacs: dict[str, tarfile.TarInfo] = {}
    with tarfile.open(a.tar, "r:gz") as t:
        members = t.getmembers()
        for m in members:
            if m.name.endswith(".trans.txt"):
                for line in t.extractfile(m).read().decode().splitlines():
                    uid, _, text = line.partition(" ")
                    texts[uid] = text
            elif m.name.endswith(".flac"):
                flacs[os.path.basename(m.name)[:-5]] = m
        ids = sorted(texts)[:N]
        os.makedirs(a.out, exist_ok=True)
        rows = []
        for uid in ids:
            data = t.extractfile(flacs[uid]).read()
            with open(os.path.join(a.out, f"{uid}.flac"), "wb") as f:
                f.write(data)
            rows.append((uid, flac_duration(data), texts[uid]))
    with open(os.path.join(a.out, "transcripts.tsv"), "w") as f:
        f.write("id\tduration_s\ttranscript\n")
        for uid, d, text in rows:
            f.write(f"{uid}\t{d:.3f}\t{text}\n")
    n26 = sum(1 for _, d, _ in rows if 2 <= d <= 6)
    with open(os.path.join(a.out, "SOURCES.md"), "w") as f:
        f.write(
            "# audio/librispeech-test-clean-200 — sources\n\n"
            "Purpose: 200 read-speech utterances + transcripts for the voice round-trip bench (M0.T05, NFR-V1) "
            "and later STT accuracy (NFR-V9; docs/research/10-architecture/environment.md §4).\n\n"
            f"- Origin: LibriSpeech ASR corpus, `test-clean` subset, {URL} (OpenSLR SLR12), downloaded 2026-10-30.\n"
            f"- Integrity: archive md5 `{MD5}` (matches https://www.openslr.org/resources/12/md5sum.txt).\n"
            "- Licence: CC BY 4.0 (V. Panayotov, G. Chen, D. Povey, S. Khudanpur, \"LibriSpeech: an ASR corpus based on "
            "public domain audio books\", ICASSP 2015). Source audio: LibriVox public-domain recordings.\n"
            f"- Method: `tools/fixtures/make-librispeech.py` (app repo): the first {N} utterance IDs in lexicographic order "
            "from all `*.trans.txt`; FLAC files copied byte-for-byte; `transcripts.tsv` = id, duration (FLAC STREAMINFO), "
            "reference transcript.\n"
            f"- Contents: {len(rows)} FLAC (16 kHz mono), {n26} of them 2–6 s long (the V1 bench takes the shortest 20 of those).\n"
            "- No personal data beyond the volunteer readers' public recordings; no sexual content.\n")
    print(f"[ok] {len(rows)} utterances -> {a.out} ({n26} between 2 and 6 s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
