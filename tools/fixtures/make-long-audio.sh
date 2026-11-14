#!/bin/bash
# M3.T06 (AT-056 testLong3h): a 3-hour FLAC from fixtures/audio/long-file/long-60min.wav × 3 (ffmpeg concat; 16 kHz
# mono FLAC), generated locally into build/fixtures/long-3h.flac (not committed); asserts ≤ 512 MB.
#   tools/fixtures/make-long-audio.sh [FIXTURES_DIR] [OUT]
set -euo pipefail
F=${1:-fixtures}
OUT=${2:-build/fixtures/long-3h.flac}
SRC="$(cd "$(dirname "$F/audio/long-file/long-60min.wav")" && pwd)/long-60min.wav"
mkdir -p "$(dirname "$OUT")"
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
for _ in 1 2 3; do echo "file '$SRC'" >> "$LIST"; done
ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$LIST" -ar 16000 -ac 1 -c:a flac "$OUT"
size=$(stat -f %z "$OUT")
[ "$size" -le $((512 * 1024 * 1024)) ] || { echo "make-long-audio: $OUT is $size bytes (> 512 MB)" >&2; exit 1; }
echo "$OUT $size bytes"
