#!/usr/bin/env bash
# AT-M0-10 (M0.T10, S-12 first-chat starter path): `make m0-gate AT=AT-M0-10`.
# Clock: download start → first streamed token of chat-0.8b (mlx-community/Qwen3.5-0.8B-MLX-4bit@5d894f8), CAS cleared
# before every run. Throttle: no admin and no Network Link Conditioner on this Mac (sudo -n fails; no prefpane), so the
# documented fallback is used: the ANTICHAT_DL_RATE_LIMIT_MBPS-style token bucket on the download lanes (SpikeDownloader until M2.T08, now DownloadCoordinator)
# (`--rate`, labelled [EMULATED]). Resume: in-process disconnect (all in-flight connections cancelled) and app kill
# (SIGKILL) at ~40 %, 3 tries each; corrupt-blob detection + re-fetch once.
# Env: SKIP_BENCH=1 (evaluate existing raw runs), RUNS50 (10), RUNS10 (5), TRIES (3), CHUNK_MB (download chunk size),
#      DD (derived-data dir of the Release app, default build/dd-bench).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT=build/at/AT-M0-10
mkdir -p "$OUT" build/perf/raw
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
exec > >(tee -a "$LOG") 2>&1
echo "== AT-M0-10 $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD)"
DD="${DD:-build/dd-bench}"
BIN="$DD/Build/Products/Release/AntiChat.app/Contents/MacOS/AntiChat"
R=build/perf/raw
CHUNK_MB="${CHUNK_MB:-8}"
TRIES="${TRIES:-3}"
echo "throttle: sudo -n: $(sudo -n true 2>&1 && echo ok || echo 'not available'); NLC prefpane: $(ls /Library/PreferencePanes ~/Library/PreferencePanes 2>/dev/null | grep -ci 'link conditioner' || true)"

if [ "${SKIP_BENCH:-0}" != 1 ]; then
  if [ ! -x "$BIN" ]; then
    xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release -derivedDataPath "$DD" ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' \
      -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS' build -quiet  # -Bench is not in a release build (tools/ci/dev-modes-guard.py)
  fi
  # The app takes the GPU lock itself, only around load + first token (the wait is excluded from the clock).
  "$BIN" -Bench firstchat --rate 50 --runs "${RUNS50:-10}" --chunk-mb "$CHUNK_MB" --test run --raw "$R/firstchat-50.jsonl"
  "$BIN" -Bench firstchat --rate 10 --runs "${RUNS10:-5}" --chunk-mb "$CHUNK_MB" --test run --raw "$R/firstchat-10.jsonl"
  : > "$R/firstchat-disconnect.jsonl"; : > "$R/firstchat-kill.jsonl"
  for t in $(seq 1 "$TRIES"); do
    "$BIN" -Bench firstchat --rate 50 --runs 1 --chunk-mb "$CHUNK_MB" --test disconnect --raw "$R/fc-tmp.jsonl"
    cat "$R/fc-tmp.jsonl" >> "$R/firstchat-disconnect.jsonl"
    # App kill: the bench SIGKILLs itself at ~40 % after saving its byte counter; the relaunch resumes.
    "$BIN" -Bench firstchat --rate 50 --runs 1 --chunk-mb "$CHUNK_MB" --test kill --counter-file "$OUT/kill-counter.txt" --raw "$R/fc-tmp.jsonl" || echo "[ok] killed (exit $?)"
    "$BIN" -Bench firstchat --rate 50 --runs 1 --chunk-mb "$CHUNK_MB" --test resume --counter-file "$OUT/kill-counter.txt" --raw "$R/fc-tmp.jsonl"
    cat "$R/fc-tmp.jsonl" >> "$R/firstchat-kill.jsonl"
  done
  "$BIN" -Bench firstchat --rate 50 --runs 1 --chunk-mb "$CHUNK_MB" --test stall --raw "$R/firstchat-stall.jsonl"
  "$BIN" -Bench firstchat --rate 0 --runs 1 --chunk-mb "$CHUNK_MB" --test corrupt --raw "$R/firstchat-corrupt.jsonl"
  rm -f "$R/fc-tmp.jsonl"
fi

python3 -I tools/m0/at-m0-10-eval.py --out "$OUT" --raw "$R" --report build/perf/report.json --commit "$(git rev-parse HEAD)"
