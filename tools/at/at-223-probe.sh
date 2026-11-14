#!/bin/bash
# AT-223 part 1 in-process leg + AT-102 follows-macOS leg (M9.T01/T04; Q-015: XCUITest cannot run on this Mac, so
# VoiceOverLabelTests / LocalisationTests are committed but not run here). Runs `-A11yProbe` (App/AntiChat/A11yProbe.swift)
# on build/AntiChat.app (Debug) with a throwaway container + Defaults suite, BackgroundRun (never takes focus), once in
# English and once per language with `-AppleLanguages (<xx>)`. Output: build/at/AT-223/<lang>/{probe,inventory}.json.
# Usage: tools/at/at-223-probe.sh [langs…]   (default: en de fr es nl pt)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
langs=("$@"); [ ${#langs[@]} -eq 0 ] && langs=(en de fr es nl pt)
rc=0
for lang in "${langs[@]}"; do
  OUT="$ROOT/build/at/AT-223/$lang"; rm -rf "$OUT"; mkdir -p "$OUT"
  suite="com.antichat.at223.$lang.$(date +%s)"
  box="$(mktemp -d /tmp/antichat-at223-XXXXXX)"
  "$BIN" -ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT" \
    -FakeEvilEnabled YES -AppleLanguages "($lang)" -DefaultsSuite "$suite" -A11yProbe "$OUT" >"$box.log" 2>&1 &
  pid=$!
  ( sleep 600; kill "$pid" 2>/dev/null ) & dog=$!
  wait "$pid"; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
  grep "A11yProbe:" "$box.log" > "$OUT/progress.log"
  if [ ! -f "$OUT/probe.json" ]; then echo "$lang: no probe.json"; tail -20 "$box.log"; rc=1; rm -rf "$box" "$box.log"; continue; fi
  rm -rf "$box" "$box.log"
  python3 -I - "$OUT/probe.json" "$lang" <<'PY' || rc=1
import json, sys
d = json.load(open(sys.argv[1])); lang = sys.argv[2]
print(f"{lang}: screens={len(d.get('screens', []))} elements={d.get('elements')} unlabeledBackingViews={len(d.get('unlabeledBackingViews', []))} "
      f"evilTitle={d.get('evilTitleAnnounced')} running={d.get('language')} placeholder={d.get('composerPlaceholder')!r}")
ok = d.get("pass") and d.get("language", "").startswith(lang)
sys.exit(0 if ok else 1)
PY
done
exit $rc
