#!/bin/bash
# M9.T05 (NFR-VID1 T4 leg, A-M5-13): the T4 default text-to-video job (vid-5b, 1280×704 × 121 f) through the app path:
# `AntiChat -Bench video --installed` (live profile → bundled signed catalog → VideoPlan → InstalledVideoModels over a
# catalog install → XPC → helper → MediaJobRunner with the ChildSafetyCheck gate → video runtime → MP4).
# Replaces build/at/T4-video/run-bench.sh, which hard-coded another worktree and a scratchpad models folder.
#   tools/perf/t4-video-bench.sh <tag> <runs> [--evil]
# Env: VIDEO_INSTALLED  catalog install root holding installs/{vid-5b,vid-taehv,csc-*} (default build/perf/t4models;
#                       created with `antichat-cli models import/install` from the dev models dir when missing)
#      APP              default build/AntiChat.app (Debug build; -Bench)      RUNTIME  default build/runtimes/video-runtime
#      OUT              default build/at/T4-video                            GPU: wrap the call in gpu-run.sh yourself
#                       (tools/perf/t05.py does: timing for T05, shared for a dry run).
# Output: $OUT/<tag>.jsonl (one row per run: final_s, res, load_avg, …), $OUT/events-<tag>.jsonl, $OUT/<tag>.log.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tag=${1:?tag}; runs=${2:?runs}; shift 2
INSTALLED="${VIDEO_INSTALLED:-$ROOT/build/perf/t4models}"
APP="${APP:-$ROOT/build/AntiChat.app}"
RUNTIME="${RUNTIME:-$ROOT/build/runtimes/video-runtime}"
OUT="${OUT:-$ROOT/build/at/T4-video}"
DEV_MODELS="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
DEV_MODELS="${DEV_MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
[ -x "$APP/Contents/MacOS/AntiChat" ] || { echo "t4-video-bench: $APP missing (make build)" >&2; exit 2; }
[ -d "$RUNTIME" ] || { echo "t4-video-bench: $RUNTIME missing (make runtime-video)" >&2; exit 2; }
if [ ! -d "$INSTALLED/installs/vid-5b" ]; then
  echo "t4-video-bench: installing vid-5b set into $INSTALLED from $DEV_MODELS" >&2
  ids=(--id vid-5b --id vid-taehv --id csc-nudity --id csc-age --id csc-age-bins)
  (cd "$ROOT" && swift run --disable-keychain --force-resolved-versions -q antichat-cli models import --models "$INSTALLED" \
      --from "$DEV_MODELS" "${ids[@]}"; swift run --disable-keychain --force-resolved-versions -q antichat-cli models install \
      --models "$INSTALLED" "${ids[@]}") || { echo "t4-video-bench: install failed" >&2; exit 2; }
fi
# M9.T05: `t4-video-bench.sh install 0` = the install only (prep, before any timed step: ~38 GB copy + a swift build).
[ "$tag" = install ] && { echo "t4-video-bench: install present in $INSTALLED"; exit 0; }
mkdir -p "$OUT/out"
echo "start $(date -u +%FT%TZ) load $(sysctl -n vm.loadavg) free $(memory_pressure | tail -1)" >> "$OUT/$tag.log"
"$APP/Contents/MacOS/AntiChat" -Bench video --installed "$INSTALLED" --runtime "$RUNTIME" --runs "$runs" \
  --out-dir "$OUT/out" --raw "$OUT/$tag.jsonl" --events "$OUT/events-$tag.jsonl" "$@" >> "$OUT/$tag.log" 2>&1
rc=$?
echo "end $(date -u +%FT%TZ) rc $rc load $(sysctl -n vm.loadavg)" >> "$OUT/$tag.log"
exit $rc
