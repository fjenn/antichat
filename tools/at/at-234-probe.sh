#!/bin/bash
# AT-234 fallback runner (M1.T25b; Q-015: XCUITest cannot enable automation mode on this Mac, so
# App/UITests/ModelInfoTests is committed but not run here). Runs the in-process Model info probe (`-ModelInfoProbe`,
# App/AntiChat/ModelInfoProbe.swift) on build/AntiChat.app (Debug), offline, fresh containers:
#   on/   real `chat-0.8b` (`-UseScriptedEngine NO`, GPU lock), `-showModelInfo YES`: 10 turns (turn 5 stopped, turn 10
#         a regenerate); leg (1) every assistant row has model_id, model_sha, mode, sampling, tok_per_s; leg (2) every
#         reply's Model info equals its row and the ⋯ item is shown; popover capture;
#   off/  ScriptedEngine `basic.jsonl`, default setting: the ⋯ item is not shown (menuItemShown false; no turns).
# Output: build/at/AT-234/probe-{on,off}/{probe.json,*.png}; exit 0 when both pass.
# Usage: tools/at/run.sh AT-234 -- tools/at/at-234-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-234"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"  # staging copy (A-M1-T05a)
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
for leg in ${LEGS:-on off}; do
  dir="$OUT/probe-$leg"
  box="$(mktemp -d /tmp/antichat-at234-XXXXXX)"
  rm -rf "$dir"
  args=(-ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -ModelInfoProbe "$dir")
  if [ "$leg" = on ]; then
    lockf /tmp/antichat-gpu.lock "$BIN" "${args[@]}" -UseScriptedEngine NO -ChatModel chat-0.8b -showModelInfo YES \
      >"$box.log" 2>&1
  else
    "$BIN" "${args[@]}" -UseScriptedEngine "$SCRIPT" >"$box.log" 2>&1
  fi
  if [ ! -f "$dir/probe.json" ]; then echo "$leg: no probe.json"; tail -20 "$box.log"; fail=1; continue; fi
  if [ "$leg" = on ]; then
    grep -q '"pass" : true' "$dir/probe.json" && grep -q '"menuItemShown" : true' "$dir/probe.json" \
      && echo "on: pass" || { echo "on: FAIL"; fail=1; }
  else
    grep -q '"menuItemShown" : false' "$dir/probe.json" && echo "off: pass (item absent)" || { echo "off: FAIL"; fail=1; }
  fi
  rm -rf "$box" "$box.log"
done
exit $fail
