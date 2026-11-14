#!/bin/bash
# fix/shared-defaults-isolation proof helper: plays "another test process" by flipping, every INTERVAL seconds, the
# values a Settings page used to read from the test tool's shared defaults domain (`swiftpm-testing-helper`, the
# `.standard` of every `swift test` process on this Mac): the quick-panel and palette shortcuts (KeyboardShortcuts),
# the chosen packs (Voice picker), What's new, the beta channel, Offline only, tool switches, a few Settings keys.
# Run it next to `make test-unit FILTER=SettingsSnapshotTests` (a test process must not see any of it). It only writes
# defaults (no CPU load) and restores the domain's previous contents on exit. While a test process of another checkout
# runs (a `swiftpm-testing-helper` whose path is outside OWN, default this checkout), it puts the domain back and
# waits: other tracks' runs are never disturbed.
# Usage: tools/ci/shared-defaults-flipper.sh [seconds]   (default 30; INTERVAL=0.2)
set -u
DOMAIN=swiftpm-testing-helper
SECONDS_TO_RUN=${1:-30}
INTERVAL=${INTERVAL:-0.2}
OWN=${OWN:-$(cd "$(dirname "$0")/../.." && pwd)}
SAVE="$(mktemp -t shared-defaults-flipper)"
defaults export "$DOMAIN" "$SAVE" 2>/dev/null || echo '{}' | plutil -convert binary1 -o "$SAVE" -
put_back() { defaults delete "$DOMAIN" 2>/dev/null; defaults import "$DOMAIN" "$SAVE"; }  # import alone merges
restore() { put_back; rm -f "$SAVE"; }
trap restore EXIT
trap 'exit 130' INT TERM

on() {
  defaults write "$DOMAIN" KeyboardShortcuts_quickPanel -bool false
  defaults write "$DOMAIN" KeyboardShortcuts_palette -string '{"carbonKeyCode":40,"carbonModifiers":768}'
  defaults write "$DOMAIN" KeyboardShortcuts_newChat -string '{"carbonKeyCode":45,"carbonModifiers":6400}'
  defaults write "$DOMAIN" packs.enabled -array chat voice photo
  defaults write "$DOMAIN" whatsNew.enabled -bool false
  defaults write "$DOMAIN" updates.beta -bool true
  defaults write "$DOMAIN" net.offlineOnly -bool true
  defaults write "$DOMAIN" toolImage -bool false
  defaults write "$DOMAIN" createFilesEnabled -bool false
  defaults write "$DOMAIN" plainTextComposer -bool true
  defaults write "$DOMAIN" menuBarItem -bool false
  defaults write "$DOMAIN" voiceSpokenLanguage -string de
}
off() {
  defaults write "$DOMAIN" KeyboardShortcuts_quickPanel -string '{"carbonKeyCode":49,"carbonModifiers":6144}'
  defaults delete "$DOMAIN" KeyboardShortcuts_palette 2>/dev/null
  defaults delete "$DOMAIN" KeyboardShortcuts_newChat 2>/dev/null
  defaults write "$DOMAIN" packs.enabled -array chat voice
  defaults write "$DOMAIN" whatsNew.enabled -bool true
  defaults write "$DOMAIN" updates.beta -bool false
  defaults write "$DOMAIN" net.offlineOnly -bool false
  defaults delete "$DOMAIN" toolImage 2>/dev/null
  defaults delete "$DOMAIN" createFilesEnabled 2>/dev/null
  defaults delete "$DOMAIN" plainTextComposer 2>/dev/null
  defaults delete "$DOMAIN" menuBarItem 2>/dev/null
  defaults delete "$DOMAIN" voiceSpokenLanguage 2>/dev/null
}

# IGNORE_PIDS="1234 5678": other checkouts' test processes known to be hung (idle for hours), not running tests.
IGNORE_PIDS=${IGNORE_PIDS:-}
foreign() {
  pgrep -fl swiftpm-testing-helper | grep -v -F "$OWN" | while read -r pid _; do
    case " $IGNORE_PIDS " in *" $pid "*) ;; *) echo "$pid" ;; esac
  done | grep -q .
}

end=$(( $(date +%s) + SECONDS_TO_RUN ))
n=0; paused=0; dirty=0
while [ "$(date +%s)" -lt "$end" ]; do
  if foreign; then
    if [ $dirty -eq 1 ]; then put_back; dirty=0; fi
    paused=$((paused + 1)); sleep 1; continue
  fi
  if [ $((n % 2)) -eq 0 ]; then on; else off; fi
  dirty=1; n=$((n + 1))
  sleep "$INTERVAL"
done
echo "shared-defaults-flipper: $n flips in ${SECONDS_TO_RUN}s (paused ${paused}s for other checkouts' test runs)"
