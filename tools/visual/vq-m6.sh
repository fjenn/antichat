#!/bin/bash
# AT-VQ-M6 capture runner in the running app (M6.T21; runbook tools/visual/vq-07-files.md). Runs the Debug build with
# `-SearchProbe <dir>` in a vq-files-* mode (App/AntiChat/VisualQAM6.swift), each leg in a fresh dev container and a
# throwaway defaults suite, the ScriptedEngine replaying a fixed turn (no model, no GPU):
#   vq-files-attach    vq-files-attach.jsonl   S-14 drop overlay, reading/ready tiles, real reading %, page pill,
#                                              error tiles + toast; S-24 Files in this chat
#   vq-files-out       vq-files-out.jsonl      S-15 PDF file card + panel, chart card, Files in this chat (produced)
#   vq-files-settings  vq-files-out.jsonl      S-21 Tools & Connections: File tools rows
# The steps that need another app (drag-out to Finder / Mail, Preview / Pages / Numbers / Keynote) stay with the
# computer-use runbook (owner grant, docs/prd/M6-owner-steps.md §2).
# The app captures its own windows (launched from this shell, which holds the Screen Recording grant) at 1440×900,
# system Light and Dark. Visual-QA capture is the one exception to the no-focus-steal rule (the app is activated).
# Then runs the automated hard checks (tools/visual/hard-checks.swift: H3 contrast, H5 copy, H6 grid, H7 sizes).
# Output: build/visual/<version>/vq-m6/<leg>/{probe.json,*.png}, build/visual/<version>/vq-m6/hard-checks.json.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
S="$ROOT/tools/fixtures/scripts"
FX="${ANTICHAT_FIXTURES:-$ROOT/fixtures}"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
OUT="$ROOT/build/visual/$VERSION/vq-m6"
fail=0
for leg in ${LEGS:-vq-files-attach vq-files-out vq-files-settings}; do
  dir="$OUT/$leg"
  rm -rf "$dir"; mkdir -p "$dir"
  echo "$leg" >"$dir/mode"
  case $leg in
    vq-files-attach) script="$S/vq-files-attach.jsonl"; mkfile -n 513m "$dir/too-large-513mb.bin" ;;
    *) script="$S/vq-files-out.jsonl" ;;
  esac
  box="$(mktemp -d /tmp/antichat-vqm6-XXXXXX)"
  suite="com.antichat.uitest.vqm6-$(basename "$box")"
  for c in updates catalog models other; do defaults write "$suite" "net.category.$c" -bool false; done
  defaults write "$suite" toolAccess -string all  # the scripted steps' tools are offered on every step
  # ANTICHAT_BACKGROUND=0: a dev-container launch is an automation run, which conceals every window (alpha 0) and
  # would capture blank frames; visual QA must show its windows (BackgroundRun header).
  ANTICHAT_BACKGROUND=0 ANTICHAT_FIXTURES="$FX" "$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" \
    -DefaultsSuite "$suite" -SkipOnboarding YES -ChatModel chat-9b-q4 -FakeHardware T1 -UseScriptedEngine "$script" \
    -SearchProbe "$dir" >"$dir/launch.log" 2>&1 &
  pid=$!
  # The probe quits the app when done; if a quit is held up (seen once after the attach leg), the runner ends its own
  # process 20 s after the probe wrote probe.json (condition-based: never a fixed sleep before the result).
  while kill -0 "$pid" 2>/dev/null && ! grep -q "SearchProbe: done" "$dir/launch.log" 2>/dev/null; do sleep 1; done
  for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && { echo "$leg: app did not quit after the probe; ended by the runner" >>"$dir/launch.log"; kill "$pid"; }
  wait "$pid" 2>/dev/null
  defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$box"
  rm -f "$dir/too-large-513mb.bin"
  if [ ! -f "$dir/probe.json" ]; then echo "$leg: no probe.json"; tail -20 "$dir/launch.log"; fail=1; continue; fi
  if grep -q '"pass" : true' "$dir/probe.json"; then echo "$leg: pass ($(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots)"
  else echo "$leg: FAIL"; fail=1; fi
done
# H5 allow list: visible text that is content, not copy — the fixture turns (user messages, scripted answers, tool
# arguments), the fixture file names and the produced file names.
python3 -I - "$ROOT" "$OUT/h5-allow.txt" <<'PY'
import glob, json, re, sys
root, out = sys.argv[1], sys.argv[2]
lines = set()
def add(s):
    for part in re.split(r"[\n]+", s):
        part = part.strip()
        if len(part) >= 3: lines.add(part)
for f in glob.glob(f"{root}/tools/fixtures/scripts/vq-files-*.jsonl"):
    for l in open(f, encoding="utf-8"):
        if l.startswith("{"):
            o = json.loads(l); [add(str(o[k])) for k in ("v", "args") if k in o]
for l in ["What does chapter 3 say?", "text-10p.pdf", "budget.xlsx", "photo.jpg", "corrupt.pdf", "encrypted.pdf", "legacy.doc",
          "too-large-513mb.bin", "Weir notes summary.pdf", "Monthly flow",
          "Make a one-page PDF of the weir notes and chart the monthly flow: Jan 12.4, Feb 10.9, Mar 15.2, Apr 18.7."]:
    add(l)
open(out, "w").write("\n".join(sorted(lines)))
PY
xcrun swift "$ROOT/tools/visual/hard-checks.swift" "$OUT" --catalog "$ROOT/App/AntiChat/Localizable.xcstrings" \
  --allow "$OUT/h5-allow.txt" --out "$OUT/hard-checks.json" || fail=1
exit $fail
