#!/bin/bash
# Incremental Debug build of the Android app ("AntiChat Dev",
# com.pocketpalai.antichatdev) with the JS bundle embedded, so it runs without Metro.
#   tools/antichat/build-android-debug.sh            -> android/app/build/outputs/apk/prod/debug/app-prod-debug.apk
#   tools/antichat/build-android-debug.sh install    -> also installs on the running emulator/device
# Never cleans. Full log: android/build/antichat-android-build.log
# ANTICHAT_ABI limits the native build (default arm64-v8a: the emulator and phones).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tools/android-env.sh"
LOG="$ROOT/android/build/antichat-android-build.log"
mkdir -p "$ROOT/android/build"
cd "$ROOT/android"
TASK=assembleProdDebug
[ "${1:-}" = install ] && TASK=installProdDebug
if ANTICHAT_EMBED_BUNDLE=1 ./gradlew "$TASK" \
  -PreactNativeArchitectures="${ANTICHAT_ABI:-arm64-v8a}" >"$LOG" 2>&1; then
  echo "build ok (android $TASK)"
else
  grep -E "^e: |error:|FAILED|What went wrong" -A3 "$LOG" | cut -c1-400 | head -40 >&2
  echo "build failed; log: $LOG" >&2
  exit 1
fi
