#!/usr/bin/env bash
# tools/bench.sh <mode> [bench args…] [--out build/perf/report.json] (M0.T04 step 7).
# Builds the app ONCE with Release optimisation into build/dd-bench (Debug numbers are never reported) and
# runs `AntiChat.app/Contents/MacOS/AntiChat -Bench <mode> …` under the one-GPU-job lock, then aggregates
# the raw runs into build/perf/report.json with tools/perf/report.py.
#   tools/bench.sh chat    --model chat-9b-q4 --tier-cap T1 --runs 20 --ctx 1k|4k
#   tools/bench.sh load    --model chat-9b-q4 --tier-cap T1 --runs 10
#   tools/bench.sh restart --model gguf:<path> --runs 10
#   tools/bench.sh family  --model chat-g12 [--image fixtures/images/ocr/x.png]
#   tools/bench.sh inproc  --model chat-9b-q4 --tier-cap T1 --runs 20     (S-3 baseline, spike only)
#   tools/bench.sh voice   --model chat-9b-q4 --tier-cap T1 --runs 20 --input fixtures/audio/librispeech-test-clean-200
#                          --mode inject|blackhole [--tts kokoro|system]   (M0.T05; aggregated by tools/audio/rt-report.py)
# Env: FIXTURES (default fixtures), NO_BUILD=1 (reuse the existing Release build), REPLACE=1 (overwrite keys),
#      BENCH_TAG (raw file suffix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:?mode}"; shift
OUT="build/perf/report.json"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
arg() { local k="$1" i; for ((i=0; i<${#ARGS[@]}; i++)); do [ "${ARGS[$i]}" = "$k" ] && { echo "${ARGS[$((i+1))]}"; return; }; done; echo "${2:-}"; }
FIXTURES="${FIXTURES:-fixtures}"
MODEL="$(arg --model chat-0.8b)"; TIER="$(arg --tier-cap none)"; CTX="$(arg --ctx 1k)"
SAFE_MODEL="$(basename "${MODEL#gguf:}")"
mkdir -p build/perf/raw
RAW="build/perf/raw/${MODE}-${SAFE_MODEL}-${TIER}-${CTX}${BENCH_TAG:+-$BENCH_TAG}.jsonl"
if [ "$MODE" = voice ]; then
  RAW="build/perf/raw/voice-${SAFE_MODEL}-${TIER}-$(arg --mode inject)-$(arg --tts kokoro)${BENCH_TAG:+-$BENCH_TAG}.jsonl"
fi
LOCK=/tmp/antichat-gpu.lock
APP="build/dd-bench/Build/Products/Release/AntiChat.app"

if [ "$MODE" = inproc ]; then
  BIN="build/dd-inproc/Build/Products/Release/antichat-bench-inproc"
  if [ "${NO_BUILD:-0}" != 1 ] || [ ! -x "$BIN" ]; then
    (cd tools/antichat-bench-inproc && xcodebuild -scheme antichat-bench-inproc -configuration Release \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/dd-inproc" -packageAuthorizationProvider netrc build -quiet)
  fi
  lockf "$LOCK" "$BIN" chat ${ARGS[@]+"${ARGS[@]}"} --fixtures "$FIXTURES" --raw "$RAW"
else
  if [ "${NO_BUILD:-0}" != 1 ] || [ ! -x "$APP/Contents/MacOS/AntiChat" ]; then
    # NDEBUG + arm64 like make build-release (RELEASE_CDEFS): Xcode's Release config does not define NDEBUG for the
    # SwiftPM C/C++ targets, so DuckDB's D_ASSERT fell back to <assert.h> on DEBUG-only helpers
    # (variant_shredding.cpp, row_group_collection.cpp) and the Release bench app did not compile (M9.T05 prep).
    xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release -derivedDataPath build/dd-bench \
      -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
      ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' build -quiet
  fi
  lockf "$LOCK" "$APP/Contents/MacOS/AntiChat" -Bench "$MODE" ${ARGS[@]+"${ARGS[@]}"} --fixtures "$FIXTURES" --raw "$RAW"
fi
echo "[ok] raw runs: $RAW"
WEIGHTS=()
if [ "$MODE" = load ] && [ -d "$HOME/Library/Application Support/AntiChat-Dev/Models/$MODEL" ]; then
  WEIGHTS=(--weights-gb "$(du -sk "$HOME/Library/Application Support/AntiChat-Dev/Models/$MODEL" | awk '{printf "%.2f", $1*1024/1e9}')")
fi
REPLACE_ARG=()
[ "${REPLACE:-0}" = 1 ] && REPLACE_ARG=(--replace)  # REPLACE=0 must not replace (${REPLACE:+…} did)
case "$MODE" in
  chat|load|restart|inproc) python3 -I tools/perf/report.py ingest --raw "$RAW" --out "$OUT" ${REPLACE_ARG[@]+"${REPLACE_ARG[@]}"} ${WEIGHTS[@]+"${WEIGHTS[@]}"} ;;
  *) : ;;
esac
