#!/bin/bash
# Runs the M6 Maestro flows (first run, models, settings) on M6's own devices.
#
#   e2e/antichat/run-m6.sh [ios|android|both] [light|dark|both] [flow ...]
#
# Same output as run.sh (screenshots under e2e/antichat/screenshots/). Flows
# whose name starts with "m6-fresh-" begin from a wiped app, as a new install.
#
# Environment (defaults are M6's devices; see docs/antichat/m6/README.md):
#   IOS_UDID        simulator (default: the one named AntiChat-M6)
#   ANDROID_SERIAL  emulator (default: emulator-5580, AVD antichat-m6)
#   METRO_PORT      default 8096
#   FONT_SCALE=max  largest text size; folder gets "-large"
#   SHOT_SUFFIX     extra folder suffix, e.g. "-small" for a small phone
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tools/android-env.sh"

PLATFORMS="${1:-both}"; THEMES="${2:-both}"; shift $(( $# > 2 ? 2 : $# )) || true
FLOWS=("$@")
[ ${#FLOWS[@]} -gt 0 ] || FLOWS=(m6-fresh-cellular m6-fresh-problems m6-fresh-first-run m6-models m6-settings m6-fresh-persist)
[ "$PLATFORMS" = both ] && PLATFORMS="ios android"
[ "$THEMES" = both ] && THEMES="light dark"

export METRO_PORT="${METRO_PORT:-8096}"
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5580}"
export IOS_UDID="${IOS_UDID:-$(xcrun simctl list devices | sed -n 's/.*AntiChat-M6 (\([0-9A-F-]*\)).*/\1/p' | head -1)}"
IOS_APP=ai.antichat.mobile.dev
ANDROID_APP=com.pocketpalai.antichatdev

wipe() { # platform: back to a new install, without reinstalling the app
  if [ "$1" = ios ]; then
    xcrun simctl terminate "$IOS_UDID" "$IOS_APP" >/dev/null 2>&1
    local data
    data="$(xcrun simctl get_app_container "$IOS_UDID" "$IOS_APP" data 2>/dev/null)" || return 0
    [ -n "$data" ] && rm -rf "$data/Documents" "$data/Library" "$data/tmp"
  else
    adb -s "$ANDROID_SERIAL" shell pm clear "$ANDROID_APP" >/dev/null
    adb -s "$ANDROID_SERIAL" reverse "tcp:$METRO_PORT" "tcp:$METRO_PORT" >/dev/null
    # A wiped app asks again; first run must not be covered by a system dialog.
    adb -s "$ANDROID_SERIAL" shell pm grant "$ANDROID_APP" android.permission.NEARBY_WIFI_DEVICES >/dev/null 2>&1
  fi
}

FAILED=0
for platform in $PLATFORMS; do
  for theme in $THEMES; do
    for flow in "${FLOWS[@]}"; do
      case "$flow" in m6-fresh-*) wipe "$platform" ;; esac
      "$HERE/run.sh" "$platform" "$theme" "$flow" || FAILED=1
    done
  done
done
exit $FAILED
