#!/bin/bash
# AT-VQ-M2 capture runner (M2.T26). Launches the Debug build with `-VisualQAProbe` (App/AntiChat/VisualQAProbe.swift)
# and takes every window shot the probe asks for with `screencapture -x -o -l <CGWindowID>` from THIS shell.
#   onboarding  fresh dev container, -ResetOnboarding YES -FakeHardware t1-m2-16, downloads from a slow loopback
#               mirror (vq-mirror.py + range-server.py --literal, 2 MB/s per file; no Hugging Face traffic): S-01…S-04
#               under Light and Dark. The mirror holds every catalog model whose blobs are in the dev store
#               (VQ_STORE, default ~/Library/Application Support/AntiChat-Dev/Models/store/sha256) or the base
#               container's store, so step 4 shows real progress (early ≠ later), not a 404 per pack.
#               S-02 default / Voice unticked / disk short; S-03 off / on / ticked / a Mac with less memory.
#   onboarding-ready   fresh container, -FakeHardware t2-m4-24 (its Chat models are in the dev store; T1's chat-4b
#               is not), the mirror at full loopback speed: S-04 Chat ready, a row that didn't finish (a file the
#               mirror lacks), Back to step 2, Chat alone → every row ready
#   onboarding-failed  fresh container, a server with no files: S-04 with Chat failed (subtitle + Retry)
#   main        a clone (cp -c) of a container with chat-0.8b/chat-4b/embed installed (VQ_MAIN_BASE, default the
#               newest /tmp/antichat-dest.*), -SkipOnboarding YES -FakeHardware t1-m2-16: empty chat, install cards
#               (Photo offered / Video not available), Settings → Capabilities (+ Advanced), Evil Mode, Storage
# Output: build/visual/<version>/vq-m2/<leg>/{*.png, probe.json}.
#
# Why the shots are taken here and not by the app (cause of the black captures, 2026-11-04): Screen Recording is a
# TCC grant of the RESPONSIBLE process. A screencapture the app spawns inherits the app's responsibility when the app
# was started by LaunchServices (`open`, Finder, Dock) — AntiChat has no grant, so `screencapture -l` returns the
# window frame with an empty (black) backing, or "could not create image from window". Started from this Terminal
# the app's children are attributed to Terminal and work, which is why M2.T20's probe was intermittent across runs.
# Taking the shot in the runner makes it independent of how the app was started.
# Each leg runs in its own defaults suite (com.antichat.uitest.vq-m2-<leg>-<pid>, removed afterwards): the one stable
# name was shared by every concurrent run on the Mac (several worktrees), so one run's state could show in another's.
# Usage: tools/visual/vq-m2.sh onboarding|onboarding-ready|onboarding-failed|main|all     (real engine in `main`: run under lockf /tmp/antichat-gpu.lock)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${APP:-$ROOT/build/AntiChat.app}/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
OUT="$ROOT/build/visual/$VERSION/vq-m2"
LEG="${1:-all}"

serve() {  # loopback "Hugging Face": the mirror (vq-mirror.py), 2 MB/s per response unless a 3rd arg says "fast"
  local root="$1" log="$2" slow=(--slow 2000)
  [ "${3:-}" = fast ] && slow=()
  python3 -I "$ROOT/tools/fixtures/range-server.py" --root "$root" --literal ${slow[@]+"${slow[@]}"} --log "$log.jsonl" > "$log" 2>&1 &
  SERVER=$!
  for _ in $(seq 50); do grep -q '^PORT ' "$log" 2>/dev/null && break; sleep 0.1; done
  PORT=$(awk '/^PORT /{print $2; exit}' "$log")
}

run_leg() {  # run_leg <name> <app args…>: launch, answer capture requests, wait for the probe to finish
  local name="$1"; shift
  local dir="$OUT/$name"
  local suite="com.antichat.uitest.vq-m2-$name-$$"  # this run's own suite: every leg starts from a first run
  rm -rf "$dir"; mkdir -p "$dir/want" "$dir/got"
  "$BIN" -ApplePersistenceIgnoreState YES -DefaultsSuite "$suite" -FreshDefaultsSuite YES -VisualQAProbe "$dir" "$@" > "$dir/app.log" 2>&1 &
  local app=$!
  local deadline=$(( $(date +%s) + ${VQ_TIMEOUT:-600} ))
  while kill -0 "$app" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
    for req in "$dir"/want/*; do
      [ -e "$req" ] || continue
      local base wid shot
      base="$(basename "$req")"; wid="${base##*.}"; shot="${base%.*}"
      screencapture -x -o -l "$wid" "$dir/$shot.png" 2>> "$dir/capture.err" || echo "$shot: screencapture rc=$?" >> "$dir/capture.err"
      rm -f "$req"; : > "$dir/got/$shot"
    done
    sleep 0.2
  done
  defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
  kill -0 "$app" 2>/dev/null && { echo "$name: timeout, app left running (pid $app)" >&2; return 1; }
  [ -f "$dir/done" ] && echo "$name: $(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots → $dir" || { echo "$name: probe did not finish"; return 1; }
}

BASE="${VQ_MAIN_BASE:-$(ls -dt /tmp/antichat-dest.* 2>/dev/null | head -1)}"
[ -d "$BASE/Models/installs/chat-0.8b" ] || { echo "need a base container with chat-0.8b installed (VQ_MAIN_BASE)"; exit 2; }
mkdir -p "$OUT"
# Before (M9 R8 / M10 harness issue 1) the server's root was `$BASE/Models/installs/chat-0.8b`: symlinks into
# `../../store`, which range-server refuses (real path outside its root) → a 404 for every file, every pack "failed".
MIRROR="${VQ_MIRROR:-$ROOT/build/visual/mirror}"
python3 -I "$ROOT/tools/visual/vq-mirror.py" --catalog "$ROOT/Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json" \
  --out "$MIRROR" --store "${VQ_STORE:-$HOME/Library/Application Support/AntiChat-Dev/Models/store/sha256}" \
  --store "$BASE/Models/store/sha256" || { echo "mirror failed"; exit 2; }
rm -f "$OUT/range-server.log.jsonl"
serve "$MIRROR" "$OUT/range-server.log"
MIRROR_SERVER=$SERVER; MIRROR_PORT=$PORT
EMPTY="$(mktemp -d /tmp/vq-empty.XXXXXX)"  # the onboarding-failed leg's server: nothing to download (404 per file)
serve "$EMPTY" "$OUT/range-server-empty.log"
EMPTY_SERVER=$SERVER; EMPTY_PORT=$PORT
serve "$MIRROR" "$OUT/range-server-fast.log" fast  # the onboarding-ready leg: Chat in seconds
FAST_SERVER=$SERVER; FAST_PORT=$PORT
trap 'kill $MIRROR_SERVER $EMPTY_SERVER $FAST_SERVER 2>/dev/null; rmdir "$EMPTY" 2>/dev/null' EXIT
rc=0
if [ "$LEG" = onboarding ] || [ "$LEG" = all ]; then
  BOX="$(mktemp -d /tmp/vq-onb.XXXXXX)"
  run_leg onboarding -ANTICHAT_DEV_CONTAINER "$BOX" -ResetOnboarding YES -FakeHardware t1-m2-16 \
    -DownloadHost "http://127.0.0.1:$MIRROR_PORT" || rc=1
  rm -rf "$BOX"
fi
if [ "$LEG" = onboarding-ready ] || [ "$LEG" = all ]; then
  BOX="$(mktemp -d /tmp/vq-onbr.XXXXXX)"
  VQ_ONB=ready run_leg onboarding-ready -ANTICHAT_DEV_CONTAINER "$BOX" -ResetOnboarding YES -FakeHardware t2-m4-24 \
    -DownloadHost "http://127.0.0.1:$FAST_PORT" || rc=1
  rm -rf "$BOX"
fi
if [ "$LEG" = onboarding-failed ] || [ "$LEG" = all ]; then
  BOX="$(mktemp -d /tmp/vq-onbf.XXXXXX)"
  VQ_ONB=failed run_leg onboarding-failed -ANTICHAT_DEV_CONTAINER "$BOX" -ResetOnboarding YES -FakeHardware t1-m2-16 \
    -DownloadHost "http://127.0.0.1:$EMPTY_PORT" || rc=1
  rm -rf "$BOX"
fi
if [ "$LEG" = main ] || [ "$LEG" = all ]; then
  BOX="$(mktemp -d /tmp/vq-main.XXXXXX)"; rmdir "$BOX"; cp -Rc "$BASE" "$BOX"
  # r66 F1: a base whose store was cleaned leaves its install views dangling (Storage then shows 0 KB per model and
  # Capabilities "Not downloaded yet"). Refill the clone's store from the dev store (APFS clones, no extra space).
  DEVSTORE="${VQ_STORE:-$HOME/Library/Application Support/AntiChat-Dev/Models/store/sha256}"
  for link in "$BOX"/Models/installs/*/*; do
    [ -L "$link" ] && [ ! -e "$link" ] || continue
    sha="$(basename "$(readlink "$link")")"; src="$DEVSTORE/${sha:0:2}/$sha"
    [ -f "$src" ] || continue
    mkdir -p "$BOX/Models/store/sha256/${sha:0:2}"; cp -c "$src" "$BOX/Models/store/sha256/${sha:0:2}/$sha"
  done
  run_leg main -ANTICHAT_DEV_CONTAINER "$BOX" -SkipOnboarding YES -FakeHardware t1-m2-16 \
    -DownloadHost "http://127.0.0.1:$MIRROR_PORT" || rc=1
  rm -rf "$BOX"
fi
exit $rc
