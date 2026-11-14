#!/bin/bash
# AT-VQ-M4 capture runner (M4.T16, journey 5 scripted; runbook tools/visual/vq-05-image.md). Launches the Debug build
# with a scripted chat turn (create_image, then edit_image on the picture in focus), the helper's ScriptedImageEngine
# and the real gate with the dev cache's detectors, and `-VisualQAProbe <dir> -VisualQAImageLeg <variant>`
# (App/AntiChat/VisualQAProbe.swift imageLeg); every window shot the probe asks for is taken from THIS shell
# (Screen Recording grant; see vq-m2.sh). Variants (VARIANTS="main missing install"):
#   main     done card → viewer (Describe the change, editor toolbar) → edit → new version + rail → Erase → Remove bg
#   missing  ANTICHAT_NO_DETECTORS=1: the safety-missing card
#   install  -FakePackState photo=absent: the Photo install card
# The blocked tile needs the forced verdict (`-ScriptedSafetyVerdict block`), compiled only in the UI-testing
# configuration (A-M4-T03a b, r241 rule 2b) — not reachable from this Debug build by design.
# 1440×900, system Light and Dark (the probe captures both). Output: build/visual/<version>/vq-05-image/<variant>/.
# `-ChatModel chat-9b-q4`: a tool-capable chat slot (the scripted engine replays the turn whatever the slot; a fresh
# container's default, the chat-only starter, is offered no tools per D-023 a, so create_image would never run).
# REAL=1: no ScriptedImageEngine — the installed catalog models (T1: img-klein-q4 + img-te-q4 + img-vae-flux2,
# csc-*, img-erase under <Models>/installs) run for real; wrap in `gpu-run.sh shared` after the memory check.
# Visual QA capture is the one exception to the no-focus-steal rule. Extra app args after `--`.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${APP:-$ROOT/build/AntiChat.app}/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
EXTRA=(); [ "${1:-}" = "--" ] && { shift; EXTRA=("$@"); }
rc=0
for variant in ${VARIANTS:-main missing install}; do
  dir="$ROOT/build/visual/$VERSION/vq-05-image/$variant"
  rm -rf "$dir"; mkdir -p "$dir/want" "$dir/got"
  BOX="$(mktemp -d /tmp/vq-image.XXXXXX)"
  TURN="$BOX/turn.jsonl"; IMG="$BOX/image.json"
  # VQ r65 (S-11): on T1 a picture turn ends with the app's own templated caption (ImageTurnPolicy) and stores no
  # assistant step the next request counts, so BOTH user turns start at segment 0, and `when` (the user's words)
  # picks the call: "lighthouse" → create_image, "purple" → edit_image. Before, segment 0 was an unconditional
  # create_image: the edit turn made a second picture, then edit_image failed `unknownSourceImage`, and the scripted
  # "Done: the sky is purple now." claimed an edit that had failed. Segment 1 only plays when a call failed at the tool
  # level, and then it says nothing in `main` / `missing` (no "Here is a lighthouse at dusk." over a failed card, no
  # "Use the repair button above" — the card's own text and action speak). `install` keeps its line: the Photo install
  # card above it is what it points to.
  said=""
  [ "$variant" = install ] && said="Pictures need the Photo pack. You can install it above."
  after='{"t":"wait","ms":1}'
  [ -n "$said" ] && after="{\"t\":\"textDelta\",\"v\":\"$said\",\"delayMs\":20}"
  printf '%s\n%s\n%s\n%s\n' \
    '{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1,"when":"lighthouse"}' \
    '{"t":"toolCallDone","id":"call_e{{n}}","name":"edit_image","args":"{\"prompt\":\"make the sky purple\",\"source_image_id\":\"{{image}}\"}","delayMs":1,"when":"purple"}' \
    '{"t":"turn"}' \
    "$after" > "$TURN"
  printf '%s' '{"steps":4,"delayMs":200}' > "$IMG"
  packs="photo=ready"; envs=()
  [ "$variant" = install ] && packs="photo=absent"
  [ "$variant" = missing ] && envs=(ANTICHAT_NO_DETECTORS=1)
  # M10 harness issue 2 / VQ r65: the tool router needs its embedder to offer create_image on T1's first turn. The
  # scripted chat engine runs in-process with no helper, so the router's embedder was never wired (`router ready=false
  # after 61 s`, `skipped=notReady`) whatever the container held; the soak runs the real engine and was not affected.
  # ANTICHAT_SCRIPTED_ROUTER=1 (DEBUG, AntiChatApp) embeds through the shared helper with the dev store's `embed`
  # (`make models-dev`), as the media jobs already do.
  envs+=(ANTICHAT_SCRIPTED_ROUTER=1)
  if [ "${REAL:-0}" = 1 ]; then
    # The fresh container's Models folder is empty, so the photo models resolve to nothing and create_image ends
    # `unavailable` (M4.T16: that was the "0 % for 300 s" of the first real run — no job was ever queued). Point the
    # container's Models at the dev models (the installs made by `antichat-cli models import`), by symlink.
    SRC="${MODELS_SRC:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
    mkdir -p "$BOX/container/Models"
    for d in installs manifests store; do [ -e "$SRC/$d" ] && ln -s "$SRC/$d" "$BOX/container/Models/$d"; done
  fi
  LAMA="${ANTICHAT_ERASE_MODEL:-$HOME/Library/Application Support/AntiChat-Dev/Models/img-erase/LaMa.mlpackage}"
  defaults delete com.antichat.uitest.vq-05 >/dev/null 2>&1
  env "${envs[@]+"${envs[@]}"}" ANTICHAT_ERASE_MODEL="$LAMA" "$BIN" -ApplePersistenceIgnoreState YES -DefaultsSuite com.antichat.uitest.vq-05 -FreshDefaultsSuite YES \
    -ANTICHAT_DEV_CONTAINER "$BOX/container" -SkipOnboarding YES -FakeHardware T1 -ChatModel chat-9b-q4 \
    -UseScriptedEngine "$TURN" $( [ "${REAL:-0}" = 1 ] || echo -UseScriptedImageEngine "$IMG" ) -FakePackState "$packs" \
    -VisualQAProbe "$dir" -VisualQAImageLeg "$variant" "${EXTRA[@]+"${EXTRA[@]}"}" > "$dir/app.log" 2>&1 &
  app=$!
  deadline=$(( $(date +%s) + ${VQ_TIMEOUT:-600} ))
  while kill -0 "$app" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
    for req in "$dir"/want/*; do
      [ -e "$req" ] || continue
      base="$(basename "$req")"; wid="${base##*.}"; shot="${base%.*}"
      screencapture -x -o -l "$wid" "$dir/$shot.png" 2>> "$dir/capture.err" || echo "$shot: screencapture rc=$?" >> "$dir/capture.err"
      rm -f "$req"; : > "$dir/got/$shot"
    done
    sleep 0.2
  done
  if kill -0 "$app" 2>/dev/null; then kill "$app"; echo "vq-05-image $variant: timeout" >&2; rc=1; fi
  rm -rf "$BOX"
  if [ -f "$dir/done" ]; then echo "vq-05-image $variant: $(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots → $dir"
  else echo "vq-05-image $variant: probe did not finish"; rc=1; fi
done
exit $rc
