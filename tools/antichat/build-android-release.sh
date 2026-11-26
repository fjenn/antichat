#!/bin/bash
# Incremental release-style build of the Android app: Hermes bytecode, dev
# support off, no Metro, signed with the debug keystore (no release key here).
#   tools/antichat/build-android-release.sh          -> android/app/build/outputs/apk/prod/release/app-prod-release.apk
#   tools/antichat/build-android-release.sh install  -> also installs on emulator-5570 (antichat-pixel)
# Keeps the debug app's id (com.pocketpalai.antichatdev) so it replaces
# "AntiChat Dev" and keeps its data; ANTICHAT_RELEASE_DEV_ID=0 builds com.pocketpalai.
# Never cleans. Full log: android/build/antichat-android-release-build.log
# ANTICHAT_ABI limits the native build (default arm64-v8a: the emulator and phones).
# ANTICHAT_RELAY_URL=http://<mac>:8790 bakes a connectors relay into the bundle
# (test builds; tools/antichat/relay-local.sh). Without it: the hosted relay.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tools/android-env.sh"
LOG="$ROOT/android/build/antichat-android-release-build.log"
APK="$ROOT/android/app/build/outputs/apk/prod/release/app-prod-release.apk"
mkdir -p "$ROOT/android/build"
cd "$ROOT/android"
if ANTICHAT_RELEASE_DEV_ID="${ANTICHAT_RELEASE_DEV_ID:-1}" ./gradlew assembleProdRelease \
  -PreactNativeArchitectures="${ANTICHAT_ABI:-arm64-v8a}" >"$LOG" 2>&1; then
  echo "build ok (android prodRelease): $APK"
else
  grep -E "^e: |error:|FAILED|What went wrong" -A3 "$LOG" | cut -c1-400 | head -40 >&2
  echo "build failed; log: $LOG" >&2
  exit 1
fi
if [ "${1:-}" = install ]; then
  adb -s "${ANTICHAT_ADB_SERIAL:-emulator-5570}" install -r "$APK"
fi
