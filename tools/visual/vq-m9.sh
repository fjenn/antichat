#!/bin/bash
# AT-VQ-M9 capture runner (M9.T08). The screens no earlier leg (vq-m2/m3/m6/m7, vq-05) captures, through the
# in-process probe `-VisualQAProbe` + `VQ_LEG=m9|m9-crash` (App/AntiChat/VisualQAProbe.swift `m9Leg`), each shot
# taken from THIS shell (the Terminal holds the Screen Recording grant; see vq-m2.sh). Scripted engine, no model,
# no GPU; a fresh dev container and a fresh `com.antichat.uitest.vq-m9-*` defaults suite per leg.
#   m9        vq-chat.jsonl (a reply per prompt): S-05 empty/typed, S-08 streaming/done + populated sidebar, S-06, S-07,
#             S-18 empty/typed/no-results, S-19, S-20, chats list, the 1180×820 repeat, S-08 stopped and error + Retry,
#             every S-21 section
#   m9-crash  vq-failures.jsonl: S-25 not enough memory, engine stalled, damaged model (Re-download), engine restart
#   m9-edit   vq-chat.jsonl: S-09 inline editor, versions, Regenerate popover, Versions viewer, ⋯ menu, branched chat (R1)
#   m9-mac    vq-chat.jsonl: S-22 quick panel and S-23 menu bar menu with Finder in front (R1)
#   m10       vq-chat.jsonl + -SimulateUpdatedFrom 0.0.0: the What's new sheet, then the first-run tour card and its dismissed state (M10)
# Light and Dark go through the app's own Settings › Appearance › Color mode (VisualQAProbe.setLook), never the
# system's: `-AppleInterfaceStyle Dark` does not reach a window whose Color mode is "system" (M10 harness issue 3).
# A probe request `want/<shot>.<CGWindowID>` is a window shot; `want/<shot>.R<x>,<y>,<w>,<h>` a screen region (popovers,
# open menus, the quick panel over another app).
# Output: build/visual/<version>/vq-m9/<leg>/{*.png, probe.json}.  Usage: tools/visual/vq-m9.sh [m9|m9-crash|m9-edit|m9-mac|m10|all]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPDIR="${APP:-$ROOT/build/AntiChat.app}"
BIN="$APPDIR/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
codesign --verify --deep --strict "$APPDIR" || { echo "codesign verify failed: $APPDIR"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
OUT="$ROOT/build/visual/$VERSION/vq-m9"
S="$ROOT/tools/fixtures/scripts"
fail=0
legs="${1:-all}"; [ "$legs" = all ] && legs="m9 m9-crash m9-edit m9-mac m10"
for leg in $legs; do
  dir="$OUT/$leg"
  rm -rf "$dir"; mkdir -p "$dir/want" "$dir/got"
  # vq-chat.jsonl: a reply per prompt the probe sends (M10 harness issue 5; s2.jsonl answered every prompt with Lisbon).
  extra=(); [ "$leg" = m10 ] && extra=(-SimulateUpdatedFrom 0.0.0)
  case $leg in m9|m9-edit|m9-mac|m10) script="$S/vq-chat.jsonl" ;; m9-crash) script="$S/vq-failures.jsonl" ;; *) echo "unknown leg $leg"; exit 2 ;; esac
  box="$(mktemp -d /tmp/antichat-vqm9-XXXXXX)"
  ANTICHAT_BACKGROUND=0 VQ_LEG=$leg "$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" \
    -DefaultsSuite "com.antichat.uitest.vq-$leg" -FreshDefaultsSuite YES -SkipOnboarding YES -FakeHardware t1-m2-16 -ChatModel chat-9b-q4 \
    -UseScriptedEngine "$script" -VisualQAProbe "$dir" "${extra[@]+"${extra[@]}"}" > "$dir/app.log" 2>&1 &
  app=$!
  deadline=$(( $(date +%s) + ${VQ_TIMEOUT:-400} ))
  while kill -0 "$app" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
    for req in "$dir"/want/*; do
      [ -e "$req" ] || continue
      base="$(basename "$req")"; wid="${base##*.}"; shot="${base%.*}"
      if [ "${wid#R}" != "$wid" ]; then
        screencapture -x -R"${wid#R}" "$dir/$shot.png" 2>> "$dir/capture.err" || echo "$shot: screencapture rc=$?" >> "$dir/capture.err"
      else
        screencapture -x -o -l "$wid" "$dir/$shot.png" 2>> "$dir/capture.err" || echo "$shot: screencapture rc=$?" >> "$dir/capture.err"
      fi
      rm -f "$req"; : > "$dir/got/$shot"
    done
    sleep 0.2
  done
  kill -0 "$app" 2>/dev/null && { echo "$leg: timeout (pid $app killed)" >&2; kill "$app"; fail=1; }
  defaults delete "com.antichat.uitest.vq-$leg" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/com.antichat.uitest.vq-$leg.plist"
  rm -rf "$box"
  [ -f "$dir/done" ] && echo "$leg: $(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots → $dir" || { echo "$leg: probe did not finish"; fail=1; }
done
exit $fail
