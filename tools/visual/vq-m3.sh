#!/bin/bash
# AT-VQ-M3 capture runner (M3.T14). Launches the Debug build with `-VisualQAProbe` + `VQ_LEG=voice`
# (App/AntiChat/VisualQAProbe.swift `voiceLeg`) and takes every window shot the probe asks for with
# `screencapture -x -o -l <CGWindowID>` from THIS shell (the Terminal holds the Screen Recording grant; see vq-m2.sh).
#   voice   a clone (cp -c) of a container with chat models installed (VQ_MAIN_BASE, default the newest
#           /tmp/antichat-dest.*), -SkipOnboarding YES -FakeHardware t1-m2-16, the scripted engine, the Voice pack
#           faked ready: a short chat, every voice-overlay state (S-16), the half-duplex hint, Settings › Voice;
#           system Light and Dark at 1440×900.
# Output: build/visual/<version>/vq-m3/voice/{*.png, probe.json}. Visual QA is the one leg allowed to take focus.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${APP:-$ROOT/build/AntiChat.app}/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
codesign --verify --deep --strict "${APP:-$ROOT/build/AntiChat.app}" || { echo "codesign verify failed"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
OUT="$ROOT/build/visual/$VERSION/vq-m3"
dir="$OUT/voice"
BASE="${VQ_MAIN_BASE:-$(ls -dt /tmp/antichat-dest.* 2>/dev/null | head -1)}"
[ -d "$BASE/Models" ] || { echo "need a base container (VQ_MAIN_BASE)"; exit 2; }
rm -rf "$dir"; mkdir -p "$dir/want" "$dir/got"
BOX="$(mktemp -d /tmp/vq-m3.XXXXXX)"; rmdir "$BOX"; cp -Rc "$BASE" "$BOX"
trap 'rm -rf "$BOX"' EXIT
defaults delete com.antichat.uitest.vq-m3 >/dev/null 2>&1
# Round 65 (S-16): one real spoken turn after the faked states (VisualQAProbe `voiceLiveTurn`): a pre-recorded
# question WAV fed as the microphone through ScriptedVoice (16 kHz mono, rendered once here with the system voice;
# the fixtures' LibriSpeech clips do not fit the chat). The helper's real VAD / turn / STT / TTS models hear and
# answer it; the transcript then shows it as a normal user turn and the scripted reply.
SPOKEN="$dir/spoken-question.wav"
VOICE_ARGS=()
if say -o "$SPOKEN" --data-format=LEI16@16000 "And what about shoes for the hills?" 2>>"$dir/capture.err"; then
  printf '{"t_ms": 2500, "wav": "%s"}\n' "$SPOKEN" > "$dir/spoken-question.jsonl"
  VOICE_ARGS=(-UseScriptedVoice "$dir/spoken-question.jsonl")
else
  echo "voice: no spoken-question WAV (say failed); the live turn is skipped" >&2
fi
VQ_LEG=voice "$BIN" -ApplePersistenceIgnoreState YES -DefaultsSuite com.antichat.uitest.vq-m3 -FreshDefaultsSuite YES -VisualQAProbe "$dir" -ANTICHAT_DEV_CONTAINER "$BOX" \
  -SkipOnboarding YES -FakeHardware t1-m2-16 -UseScriptedEngine "$ROOT/tools/fixtures/scripts/vq-voice.jsonl" -FakeVoiceInstalled YES \
  -FakePermission microphone=granted ${VOICE_ARGS[@]+"${VOICE_ARGS[@]}"} > "$dir/app.log" 2>&1 &
app=$!
deadline=$(( $(date +%s) + ${VQ_TIMEOUT:-480} ))
while kill -0 "$app" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
  for req in "$dir"/want/*; do
    [ -e "$req" ] || continue
    base="$(basename "$req")"; wid="${base##*.}"; shot="${base%.*}"
    screencapture -x -o -l "$wid" "$dir/$shot.png" 2>> "$dir/capture.err" || echo "$shot: screencapture rc=$?" >> "$dir/capture.err"
    rm -f "$req"; : > "$dir/got/$shot"
  done
  sleep 0.2
done
kill -0 "$app" 2>/dev/null && { echo "voice: timeout, app left running (pid $app)" >&2; kill "$app"; exit 1; }
[ -f "$dir/done" ] && echo "voice: $(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots → $dir" || { echo "voice: probe did not finish"; exit 1; }
