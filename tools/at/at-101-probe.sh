#!/bin/bash
# AT-101 fallback runner (M1.T23; Q-015: XCUITest cannot enable automation mode on this Mac, so AppearanceTests is
# committed but not run here). Runs the in-process Appearance probe (`-AppearanceProbe`, App/AntiChat/AppearanceProbe.swift)
# on build/AntiChat.app (Debug) with a throwaway container and Defaults suite. Output: build/at/AT-101/probe.json + captures.
# Usage: tools/at/run.sh AT-101 -- tools/at/at-101-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-101"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
rm -rf "$OUT/run"; mkdir -p "$OUT/run"
suite="com.antichat.at101.$(date +%s)"
box="$(mktemp -d /tmp/antichat-at101-XXXXXX)"
"$BIN" -ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT" \
  -DefaultsSuite "$suite" -AppearanceProbe "$OUT/run" >"$box.log" 2>&1 &
pid=$!
( sleep 180; kill "$pid" 2>/dev/null ) &
dog=$!
wait "$pid"; kill "$dog" 2>/dev/null
defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
[ -f "$OUT/run/probe.json" ] || { echo "no probe.json"; tail -20 "$box.log"; rm -rf "$box" "$box.log"; exit 1; }
rm -rf "$box" "$box.log"
cp "$OUT/run/probe.json" "$OUT/probe.json"
python3 -I - "$OUT/probe.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k, v in sorted(d.get("legs", {}).items()):
    print(k, v)
print("turn:", d.get("turn"), "pidUnchanged:", d.get("pidUnchanged"), "error:", d.get("error"))
print("pass:", d.get("pass"))
sys.exit(0 if d.get("pass") else 1)
PY
