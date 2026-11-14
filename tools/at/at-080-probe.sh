#!/bin/bash
# AT-080 / AT-250 c1 fallback runner (M7.T03; Q-015: XCUITest cannot start on this Mac, so App/UITests/WebSearchUITests
# is committed but not run here). Runs the in-process search probe (`-SearchProbe`, App/AntiChat/SearchProbe.swift) on
# build/AntiChat.app (Debug) with the ScriptedEngine, each leg in a fresh container and a throwaway defaults suite (the
# web search switch and Offline only never touch the user's defaults):
#   consent  web-plain.jsonl   c1 switch/consent/onboarding default, c4 offline chip + notice
#   chip     web-search.jsonl  c3 forced web_search, pills only for fetched sources, hover card, Sources panel (AT-250 c1)
#   reopen   (chip's container) pills + Sources panel restored after a relaunch
#   readurl  web-read.jsonl    c3 Read this URL
# Output: build/at/AT-080/probe-<leg>/{probe.json,*.png}; exit 0 when every leg passes.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-080"
S="$ROOT/tools/fixtures/scripts"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
chipbox=""
for leg in ${LEGS:-consent chip reopen readurl}; do
  dir="$OUT/probe-$leg"
  rm -rf "$dir"; mkdir -p "$dir"
  echo "$leg" >"$dir/mode"
  case $leg in
    consent) script=web-plain.jsonl; extra=(-ScriptedWebSearch NO) ;;
    chip|reopen) script=web-search.jsonl; extra=(-ScriptedWebSearch YES) ;;
    readurl) script=web-read.jsonl; extra=(-ScriptedWebSearch YES) ;;
    hint) script=web-plain.jsonl; extra=(-ScriptedWebSearch NO) ;;  # M7.T05 AT-228 c1–c4 (LEGS=hint)
  esac
  if [ "$leg" = reopen ] && [ -n "$chipbox" ]; then box="$chipbox"; else box="$(mktemp -d /tmp/antichat-at080-XXXXXX)"; fi
  [ "$leg" = chip ] && chipbox="$box"
  suite="antichat-at080-$(basename "$box")"
  # Only the search category stays as a fresh install has it; nothing else of the app goes online during the probe.
  for c in updates catalog models other; do defaults write "$suite" "net.category.$c" -bool false; done
  "$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES -ChatModel chat-9b-q4 \
    -UseScriptedEngine "$S/$script" "${extra[@]}" -SearchProbe "$dir" >"$dir/launch.log" 2>&1
  echo "$leg: exit $?"
  if [ ! -f "$dir/probe.json" ]; then echo "$leg: no probe.json"; tail -20 "$dir/launch.log"; fail=1; continue; fi
  if grep -q '"pass" : true' "$dir/probe.json"; then echo "$leg: pass"; else echo "$leg: FAIL"; cat "$dir/probe.json"; fail=1; fi
  defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
  [ "$leg" != chip ] && [ "$box" != "$chipbox" ] && rm -rf "$box"
done
[ -n "$chipbox" ] && rm -rf "$chipbox"
exit $fail
