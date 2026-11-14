#!/bin/bash
# AT-VQ-M7 capture runner + journey 12 in the running app (M7.T16; runbook tools/visual/vq-04-search.md). Runs the
# Debug build with `-SearchProbe <dir>` in a vq-* mode (App/AntiChat/VisualQAM7.swift), each leg in a fresh dev
# container and a throwaway defaults suite, the ScriptedEngine replaying a fixed turn (no model, no GPU):
#   vq-chat      web-search.jsonl + -ScriptedWebSearch YES   S-10 pills + Sources panel, S-24 search consent, S-25
#   vq-settings  web-plain.jsonl  + -ScriptedMCP             S-21 Tools page / Search rows / Connections + Composio /
#                                                            Skills, S-24 MCP + Composio consent sheets
#   vq-j12       mcp-send-message.jsonl + -ScriptedMCP        journey 12 (ApprovalCard: Deny / Allow once / Always)
#   vq-inject    web-inject.jsonl + -ScriptedWebSearch + -ScriptedMCP   untrusted ApprovalCard
# The app captures its own windows (launched from this shell, which holds the Screen Recording grant) at 1440×900,
# system Light and Dark. Visual-QA capture is the one exception to the no-focus-steal rule (the app is activated).
# Then runs the automated hard checks (tools/visual/hard-checks.swift: H3 contrast, H5 copy, H6 grid, H7 sizes).
# Output: build/visual/<version>/vq-m7/<leg>/{probe.json,*.png}, build/visual/<version>/vq-m7/hard-checks.json.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
S="$ROOT/tools/fixtures/scripts"
MCP="${ANTICHAT_FIXTURES:-$ROOT/fixtures}/web/mcp/scripted-server.jsonl"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
codesign --verify --deep --strict "$ROOT/build/AntiChat.app" || { echo "codesign verify failed"; exit 2; }
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)}"
OUT="$ROOT/build/visual/$VERSION/vq-m7"
fail=0
for leg in ${LEGS:-vq-chat vq-settings vq-j12 vq-inject}; do
  dir="$OUT/$leg"
  rm -rf "$dir"; mkdir -p "$dir"
  echo "$leg" >"$dir/mode"
  case $leg in
    vq-chat) extra=(-UseScriptedEngine "$S/web-search.jsonl" -ScriptedWebSearch YES) ;;
    vq-settings) extra=(-UseScriptedEngine "$S/web-plain.jsonl" -ScriptedMCP "$MCP") ;;
    vq-j12) extra=(-UseScriptedEngine "$S/mcp-send-message.jsonl" -ScriptedMCP "$MCP") ;;
    vq-inject) extra=(-UseScriptedEngine "$S/web-inject.jsonl" -ScriptedWebSearch YES -ScriptedMCP "$MCP") ;;
  esac
  box="$(mktemp -d /tmp/antichat-vqm7-XXXXXX)"
  suite="com.antichat.uitest.vqm7-$(basename "$box")"
  defaults delete "$suite" >/dev/null 2>&1
  for c in updates catalog models other; do defaults write "$suite" "net.category.$c" -bool false; done
  # vq-inject (R2, M9.T08): NOT "Always offer all" — on T1 that mode is cut to the 1200-token schema cap in name order,
  # so web_search and the connection's tools were never offered and both scripted calls failed. The probe picks the
  # Web search chip (pinned) and keeps "Load tools when needed" on a T3 profile, whose budget holds the connection.
  hw=T1; [ "$leg" = vq-inject ] && hw=T3
  # vq-chat: hold the scripted search 6 s so the probe captures the Searching state (s10-searching, VQ-M11 S-10).
  hold=0; [ "$leg" = vq-chat ] && hold=6000
  # ANTICHAT_BACKGROUND=0: a dev-container launch is an automation run, which conceals every window (alpha 0) and
  # would capture blank frames; visual QA must show its windows (BackgroundRun header).
  ANTICHAT_BACKGROUND=0 ANTICHAT_SCRIPTED_SEARCH_HOLD_MS=$hold "$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES \
    -ChatModel chat-9b-q4 -FakeHardware "$hw" "${extra[@]}" -SearchProbe "$dir" >"$dir/launch.log" 2>&1
  defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$box"
  if [ ! -f "$dir/probe.json" ]; then echo "$leg: no probe.json"; tail -20 "$dir/launch.log"; fail=1; continue; fi
  if grep -q '"pass" : true' "$dir/probe.json"; then echo "$leg: pass ($(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ') shots)"
  else echo "$leg: FAIL"; fail=1; fi
done
# H5 allow list: visible text that is content, not copy — the fixture turns (user messages, scripted answers, sources,
# tool arguments), catalog data (curated MCP directory, Composio app names), starter skill descriptions, chat titles.
python3 -I - "$ROOT" "$OUT/h5-allow.txt" <<'PY'
import glob, json, os, re, sys
root, out = sys.argv[1], sys.argv[2]
lines = set()
def add(s):
    for part in re.split(r"[\n]+", s):
        part = part.strip()
        if len(part) >= 3: lines.add(part)
for f in glob.glob(f"{root}/tools/fixtures/scripts/web-*.jsonl") + glob.glob(f"{root}/tools/fixtures/scripts/mcp-*.jsonl"):
    for l in open(f, encoding="utf-8"):
        if l.startswith("{"):
            o = json.loads(l); [add(str(o[k])) for k in ("v", "args") if k in o]
for l in ["What's the latest macOS version?", "Tell the team hi.", "Read the tips page and tell the team.", "Latest macOS version",
          "team_chat_send_message", "Team Chat", "chat.example", "https://chat.example/mcp"]:
    add(l)
for f in glob.glob(f"{root}/catalog/mcp-curated.yaml") + glob.glob(f"{root}/Packages/UI/Sources/AntiChatUI/Sheets/ComposioConsentSheet.swift"):
    for m in re.findall(r'(?:name|tagline|category|description):\s*"?([^"\n]+)"?', open(f, encoding="utf-8").read()): add(m)
    for m in re.findall(r'": "([A-Z][^"]+)"', open(f, encoding="utf-8").read()): add(m)
for f in glob.glob(f"{root}/Packages/Tools/Sources/AntiChatTools/Resources/**/SKILL.md", recursive=True):
    for m in re.findall(r'^(?:name|description):\s*(.+)$', open(f, encoding="utf-8").read(), re.M): add(m)
for f in glob.glob(f"{root}/Packages/Tools/Sources/AntiChatTools/Search/*Scripted*.swift") + glob.glob(f"{root}/Packages/Harness/Sources/AntiChatHarness/Tools/*Scripted*.swift"):
    for m in re.findall(r'"([^"\\]{3,})"', open(f, encoding="utf-8").read()): add(m)
open(out, "w").write("\n".join(sorted(lines)))
PY
xcrun swift "$ROOT/tools/visual/hard-checks.swift" "$OUT" --catalog "$ROOT/App/AntiChat/Localizable.xcstrings" \
  --allow "$OUT/h5-allow.txt" --out "$OUT/hard-checks.json" || fail=1
exit $fail
