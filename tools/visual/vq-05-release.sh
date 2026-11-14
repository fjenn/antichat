#!/bin/bash
# AT-VQ-M4 Release leg (M4.T16): journey 5 in a RELEASE build at this Mac's real tier, driven from outside the app.
# The in-process probe (vq-05-image.sh) and every launch argument are DEBUG-only, so this runner drives the app through
# the Accessibility API (tools/visual/axdrive.swift: AXValue / AXPress only) — no activation, no synthetic input — and takes each window shot with `screencapture -l` from this shell
# (Screen Recording + Accessibility grants on the shell).
#   APP=build/tryout/AntiChat.app tools/visual/vq-05-release.sh <out dir>
# Steps:
#   1. probe host: a copy of APP whose app + File tools services carry app.antichat.AntiChat.relprobe-adhoc[...] ids,
#      signed by tools/release/sign.sh --mode adhoc (never the shipped ids: ft-release-probe.sh explains why);
#   2. scratch home (CFFIXED_USER_HOME): Models/{installs,manifests,store} linked to the dev models (MODELS_SRC,
#      default the dev cache) — the tier's photo models must be installed there (antichat-cli models import/install);
#      onboarding.completed set; CHAT_MODEL (default chat-35b-q4) as the Normal chat override (model_override row),
#      so the 122B T4 default does not have to fit beside the photo models;
#   3. `open -g -n` (never takes focus); journey: prompt → create_image → done card → viewer → Describe the change
#      → version 2 → Erase mode (no stroke: pointer input is never synthesised) → Remove background → version 3; one shot per step in the
#      system appearance, then the same window in the other colour mode (colorMode default).
# Wrap in `gpu-run.sh shared --` after the memory check. The scratch home and probe host are removed at the end
# (KEEP=1 keeps them).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${APP:-$ROOT/build/tryout/AntiChat.app}"
OUT="${1:?usage: vq-05-release.sh <out dir>}"
MODELS_SRC="${MODELS_SRC:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
CHAT_MODEL="${CHAT_MODEL:-chat-35b-q4}"
PROMPT="${PROMPT:-Draw me a lighthouse at dusk}"
EDIT="${EDIT:-Make the sky purple}"
WAIT_IMAGE="${WAIT_IMAGE:-1500}"
PROBE_ID="app.antichat.AntiChat.relprobe-adhoc"
mkdir -p "$OUT"
LOG="$OUT/run.log"; : > "$LOG"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; cleanup; exit 1; }

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vq-05-release.XXXXXX")" && pwd -P)"
H="$WORK/home"; HOST="$WORK/host/AntiChat.app"
AX="$WORK/axdrive"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  sleep 2; [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  pkill -f "$WORK/host/AntiChat.app" 2>/dev/null
  [ "${KEEP:-0}" = 1 ] || rm -rf "$WORK"
}

xcrun swiftc -O -o "$AX" "$ROOT/tools/visual/axdrive.swift" >> "$LOG" 2>&1 || fail "axdrive build"

# 1. Probe host.
[ -d "$APP" ] || fail "missing $APP (make build-tryout)"
mkdir -p "$WORK/host"; ditto "$APP" "$HOST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PROBE_ID" "$HOST/Contents/Info.plist"
for v in "" Net; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PROBE_ID.FileTools${v:+.$v}" \
    "$HOST/Contents/XPCServices/AntiChatFileTools$v.xpc/Contents/Info.plist"
done
"$ROOT/tools/release/sign.sh" --mode adhoc --app "$HOST" --report "$WORK/sign-report.tsv" >> "$LOG" 2>&1 || fail "sign.sh"
REG="$HOME/Library/Caches/AntiChat-tests/signing-identities.tsv"; mkdir -p "$(dirname "$REG")"; touch "$REG"
for id in "$PROBE_ID" "$PROBE_ID.FileTools" "$PROBE_ID.FileTools.Net"; do
  prev=$(awk -F'\t' -v id="$id" '$1==id {print $2; exit}' "$REG")
  [ -z "$prev" ] || [ "$prev" = adhoc ] || fail "$id was first signed by '$prev' (macOS would ask the owner)"
  [ -n "$prev" ] || printf '%s\tadhoc\n' "$id" >> "$REG"
done
say "host $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOST/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOST/Contents/Info.plist")) as $PROBE_ID"

# 2. Scratch home.
SUP="$H/Library/Application Support/AntiChat"
mkdir -p "$SUP/Models" "$H/Library/Preferences"
for d in installs manifests store; do ln -s "$MODELS_SRC/$d" "$SUP/Models/$d"; done
pref() { CFFIXED_USER_HOME="$H" defaults write "$PROBE_ID" "$@"; }
pref onboarding.completed -bool YES

launch() {
  open -g -n --env CFFIXED_USER_HOME="$H" "$HOST" || fail "open"
  for _ in $(seq 60); do
    PID=$(pgrep -f "$HOST/Contents/MacOS/AntiChat" | head -1); [ -n "$PID" ] && break; sleep 1
  done
  [ -n "$PID" ] || fail "no app pid"
  say "launched pid $PID"
  # A Release copy outside /Applications asks to move itself (LetsMove): Do Not Move, don't ask again.
  if "$AX" wait "$PID" action-button-2 20; then
    "$AX" press "$PID" supression-checkbox >> "$LOG" 2>&1; "$AX" press "$PID" action-button-2 >> "$LOG" 2>&1
  fi
}
quit_app() {
  osascript -e "tell application id \"$PROBE_ID\" to quit" >/dev/null 2>&1 || kill "$PID"
  for _ in $(seq 30); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  kill -0 "$PID" 2>/dev/null && kill -9 "$PID"; PID=""
}

# First launch creates the database; then the chat override, as Settings › Capabilities › Advanced writes it.
launch
"$AX" wait "$PID" composer 120 || fail "no composer after launch"
quit_app
DB="$SUP/antichat.sqlite"; [ -f "$DB" ] || fail "no database at $DB"
sqlite3 "$DB" "INSERT OR REPLACE INTO model_override(pack, mode, model_id) VALUES ('chat', 'normal', '$CHAT_MODEL');" \
  || fail "override"
say "chat override: $CHAT_MODEL"

# 3. Journey.
launch
"$AX" wait "$PID" composer 120 || fail "no composer"
sleep 3
"$AX" resize "$PID" 1440 900 >> "$LOG" 2>&1
"$AX" press "$PID" xmark.circle.fill >> "$LOG" 2>&1  # first-run tour tip
WIN() { "$AX" windows "$PID" | awk '$2 ~ /^[0-9]+x[0-9]+$/ && $3 == "layer=0" {print $1; exit}'; }
shot() {  # shot <name>: the main window, current mode, then the other colour mode, back to System
  local w; w=$(WIN); [ -n "$w" ] || { say "no window for $1"; return; }
  screencapture -x -o -l "$w" "$OUT/$1.png" 2>> "$LOG"
  for m in light dark; do
    pref colorMode -string "$m"; sleep 1.5
    screencapture -x -o -l "$w" "$OUT/$1-$m.png" 2>> "$LOG"
  done
  pref colorMode -string system; sleep 1
  say "shot $1 (window $w)"
}
idle() {  # idle <seconds>: the reply finished (no Stop button)
  local d=$(( $(date +%s) + $1 ))
  while "$AX" find "$PID" stop >/dev/null 2>&1; do [ "$(date +%s)" -lt "$d" ] || { say "still replying"; return 1; }; sleep 2; done
}
waitfor() {  # waitfor <identifier> <seconds>
  "$AX" wait "$PID" "$1" "$2" || { say "timeout waiting for $1"; return 1; }
}

shot "rel-chat-empty"
"$AX" set "$PID" composerText "$PROMPT" >> "$LOG" 2>&1 || fail "composer text"
sleep 1; "$AX" press "$PID" voiceOrSend >> "$LOG" 2>&1 || fail "send"
waitfor userBubble 30 || fail "send: no user message"
T0=$(date +%s)
"$AX" wait "$PID" notif.explainer.notNow 30 && "$AX" press "$PID" notif.explainer.notNow >> "$LOG" 2>&1
sleep 15; shot "rel-image-running"
waitfor imageJobCard.result "$WAIT_IMAGE" || { shot "rel-image-timeout"; fail "no picture"; }
say "create: picture after $(( $(date +%s) - T0 )) s"
idle 600; say "create: reply done after $(( $(date +%s) - T0 )) s"
sleep 2; shot "rel-image-done"

# The picture itself opens the viewer (the card's ••• › Open hands the file to another app).
"$AX" press "$PID" imageJobCard.result@last >> "$LOG" 2>&1 || fail "open viewer"
waitfor imageViewer.close 30 || fail "viewer"
sleep 2; shot "rel-image-viewer"

if [ "${BEST:-0}" = 1 ]; then "$AX" press "$PID" editor.bestQuality >> "$LOG" 2>&1 || fail "best quality"; sleep 1; fi
"$AX" set "$PID" editor.describe "$EDIT" >> "$LOG" 2>&1 || fail "describe"
"$AX" press "$PID" editor.describe.send >> "$LOG" 2>&1 || fail "describe send"
T0=$(date +%s)
"$AX" waitcount "$PID" imageJobCard.result 2 "$WAIT_IMAGE" || { shot "rel-edit-timeout"; fail "no edited picture"; }
say "edit$( [ "${BEST:-0}" = 1 ] && echo ' (best quality)'): picture after $(( $(date +%s) - T0 )) s"
idle 600; say "edit: reply done after $(( $(date +%s) - T0 )) s"
sleep 2; shot "rel-image-edit-done"

"$AX" press "$PID" imageJobCard.result@last >> "$LOG" 2>&1 || fail "open viewer (2)"
waitfor versionRail.item.2 30 || fail "viewer: no version 2 in the rail"
sleep 2; shot "rel-image-viewer-versions"
"$AX" press "$PID" editor.erase >> "$LOG" 2>&1 || fail "erase tool"
waitfor editor.maskCanvas 20 || fail "mask canvas"
# Painting the mask needs pointer input, and no synthetic input may be posted (no-focus-steal): the brush and the
# LaMa erase are covered by the Debug real-model leg (vq-05-image.sh REAL=1, the same code). Here: Erase mode with the
# brush overlay and an Erase button that stays disabled without a stroke, then Cancel.
sleep 1; shot "rel-image-erase-mode"
"$AX" press "$PID" editor.erase.cancel >> "$LOG" 2>&1 || fail "erase cancel"
sleep 1
"$AX" press "$PID" editor.removeBg >> "$LOG" 2>&1 || fail "remove background"
T0=$(date +%s)
# Either a new version or the honest "no subject" notice (editor.notice; Vision finds none on a landscape).
rb=timeout; d=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$d" ]; do
  "$AX" find "$PID" versionRail.item.3 >/dev/null 2>&1 && { rb="version 3"; break; }
  "$AX" find "$PID" editor.notice >/dev/null 2>&1 && { rb="no subject (editor.notice)"; break; }
  sleep 1
done
say "remove background: $rb after $(( $(date +%s) - T0 )) s"
sleep 2; shot "rel-image-remove-background"
"$AX" press "$PID" imageViewer.close >> "$LOG" 2>&1
sleep 2; shot "rel-image-viewer-closed"
"$AX" tree "$PID" > "$OUT/ax-tree-final.txt" 2>&1
say "done"
quit_app
cleanup
exit 0
