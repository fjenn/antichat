#!/bin/bash
# M3.T06 (R-056, AT-056): fixtures/audio/formats — the same 2-min clip as WAV, MP3, M4A, AAC and FLAC.
# Source: the first 120.75 s of audio/long-file/long-60min.wav (LibriSpeech test-clean, CC BY 4.0; the cut sits in the
# 0.5 s gap before the utterance at [00:02:01]), so `clip.txt` = its first 14 ground-truth lines.
# Encoders: macOS afconvert for WAV / M4A / AAC / FLAC; MP3 with the toolchain ffmpeg (afconvert has no MP3 encoder).
#   tools/fixtures/make-audio-formats.sh [FIXTURES_DIR]     (default: ./fixtures)
set -euo pipefail
F=${1:-fixtures}
SRC="$F/audio/long-file/long-60min.wav"
OUT="$F/audio/formats"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$SRC" -t 120.75 -ar 16000 -ac 1 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact "$TMP/clip.wav"
cp "$TMP/clip.wav" "$OUT/clip.wav"
afconvert -f m4af -d aac -b 32000 "$TMP/clip.wav" "$OUT/clip.m4a"
afconvert -f adts -d aac -b 32000 "$TMP/clip.wav" "$OUT/clip.aac"
afconvert -f flac -d flac "$TMP/clip.wav" "$OUT/clip.flac"
ffmpeg -nostdin -loglevel error -y -i "$TMP/clip.wav" -c:a libmp3lame -b:a 32k -map_metadata -1 -fflags +bitexact "$OUT/clip.mp3"
head -14 "$F/audio/long-file/long-60min.txt" > "$OUT/clip.txt"
cat > "$OUT/SOURCES.md" <<'MD'
# audio/formats — sources

Purpose: the audio-file transcription format matrix (R-056, AT-056 `FileTranscriberTests`; M3.T06).

- `clip.{wav,mp3,m4a,aac,flac}`: one 2:00.75 clip, the first 120.75 s of `audio/long-file/long-60min.wav`
  (LibriSpeech test-clean, https://www.openslr.org/resources/12/test-clean.tar.gz, CC BY 4.0), cut in the 0.5 s gap
  before the utterance at [00:02:01]. WAV 16 kHz mono 16-bit; M4A (AAC-LC in MPEG-4) and AAC (ADTS) at 32 kb/s and
  FLAC by macOS `afconvert`; MP3 32 kb/s by ffmpeg (libmp3lame).
- `clip.txt`: the clip's 14 ground-truth lines (`[hh:mm:ss] TEXT`, from `long-60min.txt`).
- Generator: `tools/fixtures/make-audio-formats.sh` (app repo). Encoded bytes depend on the encoder versions; the
  lock pins the committed files.
- Rule: no real personal data beyond the volunteer readers' public recordings; no sexual content of any kind.
MD
ls -la "$OUT"
