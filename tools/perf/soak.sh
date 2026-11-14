#!/bin/bash
# M9.T06 AT-NFR-S3: the long mixed-session soak (`make soak HOURS=8 TIER=T1`).
#   tools/perf/soak.sh --hours 8 --tier T1                  the AT run (real models, T1 cap B = the tier's budget)
#   tools/perf/soak.sh --minutes 20 --tier T1               a dry run (same legs, 60 s samples; never a pass of the AT)
#   options: --images real|scripted   real = img-klein q4 @ 768 through sd-server (default); scripted = ScriptedImageEngine
#                                     buffers of the image footprint (the T05 mini-soak's workload)
#            --skip voice,import      leave legs out (smoke runs only; recorded in the result)
#            --app <AntiChat.app>     the perf-harness app to copy (default build/perf-app/AntiChat.app, `make build-perf`)
#            --images-per-hour N      (default 3)   --run-dir <dir>  (default build/soak/<stamp>)
#            --no-report              skip the AT-NFR-S3 verdict (tools/perf/swap-session.sh reuses the driver)
#            --launch ls|direct       ls (default): LaunchServices, like a user's launch (see "Launch" below);
#                                     direct: exec the binary from this shell (the pre-r65 launch; A/B runs only)
# The driver is the app itself (`-SoakProbe`, App/AntiChat/SoakProbe.swift = the spec's SoakDriver): a background run in
# a throwaway dev container (never the owner's container, never key or front, no XCUITest, no global input), real
# models, ScriptedVoice through the real STT/TTS. Each run uses its OWN copy of the app (build/soak/<stamp>/AntiChat.app),
# so the sampler and the crash scan match only this soak's processes (pid / executable path), never the other test runs'
# AntiChat processes. GPU: `~/AntiChat-tools/gpu-run.sh shared` (never the timing lock; the soak is not a timing run),
# with its wall-clock limit raised to the run length + 1 h. The Mac stays awake for the run (`caffeinate -dimsu`).
# Launch (AT-NFR-S3 method note, docs/prd/AT-NFR-S3-method.md): through LaunchServices in the background
# (`open -n -g -W`, never activated) with `ANTICHAT_BACKGROUND_POLICY=accessory`: the app stays a background run (no
# Dock icon, concealed windows, never active, input in-process) but its main thread is scheduled like a user's app's.
# Measured on macOS 26.6 (18 CPUs): any `.regular`/`.accessory` app's main thread runs at priority 46 (47 while
# active), visible, off-screen, minimised or alpha-0 windows alike; a `.prohibited` app's at 31, which the kernel keeps
# whatever QoS the thread asks for. Finder, Chrome, Messages: 46/47. At 31 the main thread lost to every other app's UI
# thread on a busy Mac: in a loaded 30-min run its stalls ≥ 1 s were all runnable-not-running (main CPU 0.07–0.4 s over
# 1.1–3.1 s). The hang watchdog and the 2 s bar are unchanged. LaunchServices does not return the app's exit status:
# the run's `exit_code` is `open`'s; a crash still fails the verdict (no result.json, the .ips scan).
# Samples: the probe every 5 min (+ one per loop at the same phase), soak-sampler.py every 1 s (peak phys_footprint of
# the engine helper + children). Verdict: tools/perf/soak-report.py → build/at/AT-NFR-S3/<date>.json + memory.png
# (dry runs: <date>-dry.json + memory-dry.png). Exit 0 = pass (or a completed dry run), 1 = fail, 2 = setup error.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOURS="${HOURS:-}" TIER="${TIER:-T1}" MINUTES="" IMAGES=real SKIP="" IPH=3 RUN="" REPORT=1 LAUNCH=ls APP_SRC="${SOAK_APP_SRC:-$ROOT/build/perf-app/AntiChat.app}"
[ "$TIER" = min ] && TIER=T1  # the Makefile's TIER default
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
    --images) IMAGES="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --app) APP_SRC="$2"; shift 2 ;;
    --images-per-hour) IPH="$2"; shift 2 ;;
    --run-dir) RUN="$2"; shift 2 ;;
    --no-report) REPORT=0; shift ;;
    --launch) LAUNCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "usage: $0 --hours H | --minutes M [--tier T1] [--images real|scripted] [--skip legs] [--app path]" >&2; exit 64 ;;
  esac
done
DRY=0
if [ -n "$MINUTES" ]; then DRY=1
elif [ -n "$HOURS" ]; then MINUTES=$(python3 -c "print(float('$HOURS') * 60)")
else echo "soak: --hours H (the AT: 8) or --minutes M (dry run)" >&2; exit 64; fi
HOURS=$(python3 -c "print(round(float('$MINUTES') / 60, 3))")
python3 -c "import sys; sys.exit(0 if float('$HOURS') >= 2 else 1)" || DRY=1
case "$IMAGES" in real|scripted) ;; *) echo "--images real|scripted" >&2; exit 64 ;; esac
case "$LAUNCH" in ls|direct) ;; *) echo "--launch ls|direct" >&2; exit 64 ;; esac

# Models (dev store, `make models-dev TIER=T1` + evil-T1 + the voice set): same per-tier set as tools/soak/mini-soak.sh.
MODELS="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
MODELS="${MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
case "$TIER" in
  T0) CHAT=chat-2b; EVIL=""; IMG_GB=2.5 ;;
  T1) CHAT=chat-9b-q4; EVIL=evil-9b; IMG_GB=6.3 ;;
  T2-24) CHAT=chat-9b-q4; EVIL=evil-9b; IMG_GB=6.2 ;;
  T3-48) CHAT=chat-35b-q4; EVIL=evil-35b-q4; IMG_GB=6.0 ;;
  *) echo "soak: unknown tier $TIER (T0|T1|T2-24|T3-48)" >&2; exit 64 ;;
esac
FAKE_HW="${SOAK_FAKE_HARDWARE:-${TIER%%-*}}"
need=("$CHAT" embed stt tts turn-coreml vad)
[ -n "$EVIL" ] && need+=("$EVIL")
[ "$IMAGES" = real ] && need+=(img-klein-q4 img-te-q4 img-vae-flux2 csc-age csc-nudity)
missing=()
for k in "${need[@]}"; do
  [ -e "$MODELS/installs/$k" ] || [ -e "$MODELS/$k" ] || missing+=("$k")
done
if [ ${#missing[@]} -gt 0 ]; then echo "soak: models missing in $MODELS: ${missing[*]} (make models-dev TIER=$TIER / evil-$TIER)" >&2; exit 2; fi

# Fixtures: the repo's, or the main checkout's when this is a worktree without them.
FIX="${FIXTURES:-$ROOT/fixtures}"
if [ ! -d "$FIX/projects/qa-50" ]; then
  common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$common" ] && [ -d "$(dirname "$common")/fixtures/projects/qa-50" ] && FIX="$(dirname "$common")/fixtures"
fi
for f in projects/qa-50/questions.jsonl audio/dictation/q02.wav chats/chatgpt-export/export.zip chats/claude-export/export.zip; do
  [ -e "$FIX/$f" ] || { echo "soak: fixture $FIX/$f missing" >&2; exit 2; }
done
# Git LFS pointers instead of content (a fixtures checkout without `git lfs pull`): the voice leg's WAV then fails in
# ScriptedVoice (the helper reports only `voice.unavailable`) and the project documents index as pointer text. Refuse.
pointers=()
for f in "$FIX/audio/dictation/q02.wav" "$FIX/chats/chatgpt-export/export.zip" "$FIX/chats/claude-export/export.zip" \
         "$FIX"/projects/qa-50/docs/*; do
  case "$(head -c 64 "$f" 2>/dev/null | LC_ALL=C tr -d '\0')" in "version https://git-lfs.github.com/spec/"*) pointers+=("${f#$FIX/}") ;; esac
done
if [ ${#pointers[@]} -gt 0 ]; then
  echo "soak: ${#pointers[@]} fixture(s) in $FIX are Git LFS pointers, e.g. ${pointers[0]} (cd $FIX && git lfs install --local && git lfs pull)" >&2
  exit 2
fi

# The perf-harness app (optimized, test hooks on; tools/perf/build-perf.sh), copied for this run.
[ -x "$APP_SRC/Contents/MacOS/AntiChat" ] || { echo "soak: $APP_SRC missing (make build-perf)" >&2; exit 2; }
BUILD_JSON="$(dirname "$APP_SRC")/build.json"
if ! python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1]))["buildinfo"]; sys.exit(0 if b.get("perf_harness") and b.get("optimized") and not b.get("debug") else 1)' "$BUILD_JSON" 2>/dev/null; then
  echo "soak: $APP_SRC is not a verified perf-harness build ($BUILD_JSON; make build-perf)" >&2; exit 2
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN="${RUN:-$ROOT/build/soak/$STAMP}"
[ -e "$RUN/AntiChat.app" ] && { echo "soak: $RUN already used" >&2; exit 2; }
mkdir -p "$RUN/probe" "$RUN/sampler" "$RUN/container"
cp -c -R "$APP_SRC" "$RUN/AntiChat.app" 2>/dev/null || cp -R "$APP_SRC" "$RUN/AntiChat.app"
cp "$BUILD_JSON" "$RUN/build.json"
EXE="$RUN/AntiChat.app/Contents/MacOS/AntiChat"
printf '{"t_ms": 1500, "wav": "%s"}\n' "$FIX/audio/dictation/q02.wav" > "$RUN/voice.jsonl"
SAMPLE_S=300; [ "$DRY" = 1 ] && SAMPLE_S=60
python3 -I - "$RUN/probe/config.json" "$MINUTES" "$SAMPLE_S" "$IMAGES" "$IMG_GB" "$FIX" "$TIER" "$SKIP" "$IPH" <<'PY'
import json, sys
out, minutes, sample_s, images, gb, fix, tier, skip, iph = sys.argv[1:]
json.dump({"minutes": float(minutes), "sample_s": float(sample_s), "images_per_hour": float(iph), "image_mode": images,
           "image_gb": float(gb), "image_quant": "q4", "image_res": 768, "fixtures": fix, "tier": tier,
           "skip": [s for s in skip.split(",") if s]}, open(out, "w"), indent=1)
PY

ARGS=(-ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$RUN/container" -SkipOnboarding YES -SoakProbe "$RUN/probe"
      -FakeHardware "$FAKE_HW" -ChatModel "$CHAT" -FakeVoiceInstalled YES -UseScriptedVoice "$RUN/voice.jsonl")
[ -n "$EVIL" ] && ARGS+=(-EvilChatModel "$([ "$TIER" = T3-48 ] && echo "$EVIL" || echo "llama:$EVIL")")
GPU_RUN="${ANTICHAT_GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}"
if [ -n "${ANTICHAT_GPU_LOCK_HELD:-}" ]; then WRAP=()
elif [ -x "$GPU_RUN" ]; then WRAP=("$GPU_RUN" shared --)
else WRAP=(); echo "soak: no $GPU_RUN; running without the GPU scheduler" >&2; fi
export GPU_RUN_MAX_MIN=$(python3 -c "print(int(float('$MINUTES') + 90))")  # the run + setup, never cut short at 6 h
START_EPOCH=$(date +%s)
echo "soak: $TIER ${HOURS} h (dry=$DRY), images $IMAGES, chat $CHAT, evil ${EVIL:-none}, launch $LAUNCH, fixtures $FIX → $RUN"
if [ "$LAUNCH" = ls ]; then
  caffeinate -dimsu ${WRAP[@]+"${WRAP[@]}"} /usr/bin/open -n -g -W --env "ANTICHAT_FIXTURES=$FIX" --env ANTICHAT_BACKGROUND=1 \
    --env ANTICHAT_BACKGROUND_POLICY=accessory --stdout "$RUN/app.stdout.log" --stderr "$RUN/app.log" "$RUN/AntiChat.app" \
    --args "${ARGS[@]}" > "$RUN/open.log" 2>&1 &
else
  ANTICHAT_FIXTURES="$FIX" ANTICHAT_BACKGROUND=1 caffeinate -dimsu ${WRAP[@]+"${WRAP[@]}"} "$EXE" "${ARGS[@]}" \
    > "$RUN/app.log" 2>&1 &
fi
WRAPPER=$!
APP_PID="" SAMPLER=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
}
trap 'echo "soak: interrupted" >&2; cleanup; exit 130' INT TERM
# The app starts once gpu-run grants a shared slot (it may wait while a timing run holds the GPU).
while kill -0 "$WRAPPER" 2>/dev/null; do
  APP_PID=$(pgrep -f "^$EXE " | head -n 1)
  [ -n "$APP_PID" ] && break
  sleep 2
done
if [ -n "$APP_PID" ]; then
  # The main thread's scheduling priority, recorded for the method note (ps -M: the first thread is the main thread).
  sleep 5
  MAIN_PRI=$(ps -M -p "$APP_PID" | awk 'NR==2{print $6}')
  echo "soak: app main-thread priority $MAIN_PRI (launch $LAUNCH)"
  python3 -I "$ROOT/tools/perf/soak-sampler.py" --bundle "$RUN/AntiChat.app" --app-pid "$APP_PID" --out "$RUN/sampler" &
  SAMPLER=$!
  echo "soak: app pid $APP_PID, sampler pid $SAMPLER"
fi
wait "$WRAPPER"
RC=$?
# `open -W` (or gpu-run's time limit) ended while the app still runs: stop it (this run's pid only).
[ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && { echo "soak: app $APP_PID still running after its launcher; stopping it" >&2; kill "$APP_PID"; }
[ -n "$SAMPLER" ] && { sleep 7; kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; }
python3 -I - "$RUN/run.json" <<PY
import json, sys
json.dump({"start_epoch": $START_EPOCH, "end_epoch": $(date +%s), "bundle": "$RUN/AntiChat.app", "app_pid": int("${APP_PID:-0}"),
           "exit_code": $RC, "hours": $HOURS, "minutes": $MINUTES, "tier": "$TIER", "dry": bool($DRY), "images": "$IMAGES",
           "skip": "$SKIP", "launch": "$LAUNCH", "main_thread_priority": "${MAIN_PRI:-}", "commit": "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)", "build": json.load(open("$RUN/build.json")),
           "fixtures": "$FIX", "gpu_run": "${WRAP[*]:-none}"}, open(sys.argv[1], "w"), indent=1)
PY
[ "$REPORT" = 1 ] || { echo "soak: app exit $RC, run dir $RUN (no report)"; exit $([ "$RC" = 0 ] && echo 0 || echo 1); }
OUT="$ROOT/build/at/AT-NFR-S3"
mkdir -p "$OUT"
DATE=$(date +%Y-%m-%d)
SUFFIX=""; [ "$DRY" = 1 ] && SUFFIX="-dry"
PY="$ROOT/tools/.venv/bin/python"; [ -x "$PY" ] || PY=python3
"$PY" -I "$ROOT/tools/perf/soak-report.py" --run "$RUN" --out "$OUT/$DATE$SUFFIX.json" --png "$OUT/memory$SUFFIX.png"
