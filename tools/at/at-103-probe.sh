#!/bin/bash
# AT-103 / AT-104 fallback runner (M1.T24; Q-015: XCUITest cannot enable automation mode on this Mac, so
# ShortcutsTests / MenusWindowsTests are committed but not run here). Runs the in-process probe (`-ShortcutsProbe`,
# App/AntiChat/ShortcutsProbe.swift) on build/AntiChat.app (Debug), throwaway container + Defaults suite:
#   shortcuts  AT-103 (1)(2) + AT-104 (1)                       → build/at/AT-103/run/shortcuts.json
#   windows    AT-104 (2) two windows, quit normally (state kept); restore: relaunch, same container → restore.json
#   lastwin    AT-104 (3) Menu bar item On: still running after the last window closes; Off: the app exits itself.
# Usage: tools/at/run.sh AT-103 -- tools/at/at-103-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-103"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
rm -rf "$OUT/run"; mkdir -p "$OUT/run"
stamp=$(date +%s)
BID=$(defaults read "$ROOT/build/AntiChat.app/Contents/Info" CFBundleIdentifier 2>/dev/null)

launch() {  # <box> <suite> <mode> [extra…]; returns the exit status; kills after 180 s
  local box=$1 suite=$2 mode=$3; shift 3
  "$BIN" -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT" -DefaultsSuite "$suite" \
    -ShortcutsProbe "$OUT/run" -ShortcutsMode "$mode" "$@" >>"$OUT/run/app.log" 2>&1 &
  local pid=$!
  ( sleep 180; kill "$pid" 2>/dev/null ) & local dog=$!
  wait "$pid"; local rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  return $rc
}

SAVED="$HOME/Library/Saved Application State/$BID.savedState"
[ -n "$BID" ] && rm -rf "$SAVED"  # start from no saved windows
box="$(mktemp -d /tmp/antichat-at103-XXXXXX)"; suite="com.antichat.at103.$stamp"
launch "$box" "$suite" shortcuts -ApplePersistenceIgnoreState YES
# Windows + restoration: same container, state restoration on (no -ApplePersistenceIgnoreState).
box2="$(mktemp -d /tmp/antichat-at103w-XXXXXX)"
[ -n "$BID" ] && rm -rf "$SAVED"
launch "$box2" "$suite.w" windows
launch "$box2" "$suite.w" restore
# Last window: On keeps the process (the probe writes lastwin.json and quits); Off exits before writing it.
launch "$box" "$suite.on" lastwin -ApplePersistenceIgnoreState YES -menuBarItem YES
mv -f "$OUT/run/lastwin.json" "$OUT/run/lastwin-on.json" 2>/dev/null
start=$(date +%s)
launch "$box" "$suite.off" lastwin -ApplePersistenceIgnoreState YES -menuBarItem NO
echo "{\"exitedItself\": $([ -f "$OUT/run/lastwin.json" ] && echo false || echo true), \"seconds\": $(( $(date +%s) - start ))}" > "$OUT/run/lastwin-off.json"
for s in "$suite" "$suite.w" "$suite.on" "$suite.off"; do defaults delete "$s" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$s.plist"; done
[ -n "$BID" ] && rm -rf "$HOME/Library/Saved Application State/$BID.savedState"
rm -rf "$box" "$box2"
python3 -I - "$OUT" <<'PY'
import json, os, sys
o = sys.argv[1]
def load(n):
    try: return json.load(open(os.path.join(o, "run", n)))
    except Exception as e: return {"pass": False, "error": str(e)}
s, r, on, off = load("shortcuts.json"), load("restore.json"), load("lastwin-on.json"), load("lastwin-off.json")
ats = {
  "AT-103": {"1-defaults-perform": s.get("AT-103-1", {}).get("pass", False), "2-table-rebind-conflict-restore": s.get("AT-103-2", {}).get("pass", False)},
  "AT-104": {"1-menus": s.get("AT-104-1", {}).get("pass", False), "2-windows-restored": r.get("pass", False),
             "3-last-window": on.get("pass", False) and off.get("exitedItself", False)},
}
for k in ("AT-103-1", "AT-103-2", "AT-104-1"): print(k, s.get(k))
print("restore", r); print("lastwin on", on); print("lastwin off", off)
for at, legs in ats.items(): print(at, legs)
ok = all(all(v.values()) for v in ats.values())
json.dump({"form": "in-process probe (Q-015 fallback)", "pass": ok, "ats": ats}, open(os.path.join(o, "probe.json"), "w"), indent=2)
print("pass:", ok); sys.exit(0 if ok else 1)
PY
