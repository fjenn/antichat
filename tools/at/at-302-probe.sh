#!/bin/bash
# AT-302 fallback runner (M1.T21; Q-015: XCUITest cannot enable automation mode on this Mac, so App/UITests/DraftTests
# is committed but not run here). Runs the in-process draft probe (`-DraftProbe`, App/AntiChat/DraftProbe.swift) on
# build/AntiChat.app (Debug), ScriptedEngine `basic.jsonl`, offline, each leg in a fresh container:
#   switch  one launch: two chats, a draft (+ paste card) in each, restored on every switch, rows ≤ 1 s, send clears;
#   quit    launch 1 types and terminates at once (willTerminate flush); launch 2 restores text + card;
#   crash   launch 1 types, SIGKILLs itself 1.2 s after the last keystroke; launch 2 restores, updated_at lag ≤ 1 s.
# Output: build/at/AT-302/probe-<leg>/{probe.json,typed.json,*.png}; exit 0 when every leg passes.
# Usage: tools/at/run.sh AT-302 -- tools/at/at-302-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-302"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"  # staging copy (A-M1-T05a)
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
for leg in ${LEGS:-switch quit crash}; do
  dir="$OUT/probe-$leg"
  box="$(mktemp -d /tmp/antichat-at302-XXXXXX)"
  rm -rf "$dir"; mkdir -p "$dir"
  echo "$leg" >"$dir/mode"
  args=(-ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT"
        -DraftProbe "$dir")
  "$BIN" "${args[@]}" >"$box.launch1.log" 2>&1
  echo "$leg: launch 1 exit $?"
  if [ "$leg" != switch ]; then
    [ -f "$dir/typed.json" ] || { echo "$leg: no typed.json"; tail -20 "$box.launch1.log"; fail=1; continue; }
    /usr/bin/sqlite3 -readonly "$box/antichat.sqlite" "SELECT chat_id, length(text), updated_at FROM draft" >"$dir/rows-after-launch1.txt" 2>&1
    "$BIN" "${args[@]}" >"$box.launch2.log" 2>&1
    echo "$leg: launch 2 exit $?"
  fi
  if [ ! -f "$dir/probe.json" ]; then echo "$leg: no probe.json"; tail -20 "$box".launch*.log; fail=1; continue; fi
  if grep -q '"pass" : true' "$dir/probe.json"; then echo "$leg: pass"; else echo "$leg: FAIL"; cat "$dir/probe.json"; fail=1; fi
  rm -rf "$box" "$box".launch*.log
done
exit $fail
