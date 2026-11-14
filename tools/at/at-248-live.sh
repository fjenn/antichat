#!/bin/bash
# M7.T16 headline: AT-248 c1 / AT-254 T1 search answer latency in the running app (SearchProbe `live` leg: real T1
# model through the engine helper, live keyless engines, chip on, 20 runs of "What's the latest macOS version?").
# Run it under the timing slot: ~/AntiChat-tools/gpu-run.sh timing -- tools/at/at-248-live.sh
# A throwaway container whose Models/ is the developer's installed models (symlink, read-only use); background mode
# (never takes focus), so window-draw legs read slower than on a frontmost window (BackgroundRun header).
# The AT-248 c1 EVIDENCE run is READER=1 (below): foreground app + the XCUITest rendered-pill reader; a background run
# cannot count pills on this Mac (its SwiftUI window is never drawn, so MarkdownView never parses; 2026-11-10).
# Pills count once the citations settled: the probe waits (≤ 30 s) until no pill is drawn in the checking state.
# Output: build/at/AT-248/<date>-live/{probe.json,runs.partial.json}.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${APP:-$ROOT/build/AntiChat.app}/Contents/MacOS/AntiChat"
MODELS="${ANTICHAT_MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
MODEL="${MODEL:-chat-9b-q4}"
[ -x "$BIN" ] || { echo "missing $BIN (make build)"; exit 2; }
# M7 bars-2: never launch a bundle dyld would reject (a broken build put an "AntiChat cannot be opened" dialog on the
# owner's screen, 2026-11-10): the signature must verify, and an ad-hoc hardened-runtime app that embeds frameworks
# needs disable-library-validation (tools/release/sign.sh --mode adhoc adds it; a plain Debug build does not).
APPDIR="$(cd "$(dirname "$BIN")/../.." && pwd)"
codesign --verify --deep --strict "$APPDIR" 2>&1 || { echo "refusing to launch: $APPDIR fails codesign --verify --deep --strict"; exit 3; }
if codesign -dv "$APPDIR" 2>&1 | grep -q 'flags=.*adhoc.*runtime' && [ -n "$(ls "$APPDIR/Contents/Frameworks" 2>/dev/null)" ] &&
   ! codesign -d --entitlements - --xml "$APPDIR" 2>/dev/null | grep -q 'disable-library-validation'; then
  echo "refusing to launch: $APPDIR is ad-hoc + hardened runtime with embedded frameworks but lacks disable-library-validation (sign it with tools/release/sign.sh --mode adhoc)"; exit 3
fi
[ -d "$MODELS/installs/$MODEL" ] || { echo "missing $MODELS/installs/$MODEL"; exit 2; }
dir="$ROOT/build/at/AT-248/$(date +%F)-${TAG:-live}"
rm -rf "$dir"; mkdir -p "$dir"
echo live >"$dir/mode"; echo "${RUNS:-20}" >"$dir/runs"
box="$(mktemp -d /tmp/antichat-at248-XXXXXX)"
# M7 bars-3: the probe runs with the on-demand cite-check model installed (the app has it after its first web answer),
# so the full citation check (deterministic + MiniCheck + verifier) runs like in use. The Models dir is a private
# overlay (every entry a symlink into the developer's Models; installs/cite-check a view of APFS clones of the dev
# copy, checked against the catalog lock); the developer's Models dir is never written. CITE_CHECK=0: plain symlink.
if [ "${CITE_CHECK:-1}" = 1 ] && [ -d "$MODELS/cite-check" ] && [ ! -e "$MODELS/installs/cite-check" ]; then
  mkdir "$box/Models" "$box/Models/installs"
  for e in "$MODELS"/*; do [ "$(basename "$e")" = installs ] || ln -s "$e" "$box/Models/$(basename "$e")"; done
  for e in "$MODELS/installs"/*; do ln -s "$e" "$box/Models/installs/$(basename "$e")"; done
  python3 -I "$ROOT/tools/at/cite-check-view.py" "$MODELS/cite-check" "$box/Models/installs/cite-check" "$ROOT/catalog/catalog.lock.json" \
    || { echo "cite-check view failed"; rm -rf "$box"; exit 2; }
  echo cite-check >"$dir/cite-check"
else
  ln -s "$MODELS" "$box/Models"
fi
suite="antichat-at248-$(basename "$box")"
for c in updates catalog models other; do defaults write "$suite" "net.category.$c" -bool false; done
uptime | sed 's/.*load/load/' >"$dir/load-before.txt"
# M7 at248: READER=1 = the AT-248 c1 evidence run. The app runs FOREGROUND (ANTICHAT_BACKGROUND=0: on this Mac a
# background-mode SwiftUI window is never drawn, so nothing renders), and the XCUITest reader
# (App/UITests/AT248RenderedPillsUITests.swift, attach mode) counts the settled pills in the window's accessibility
# tree after every run and saves a window screenshot; the reader launches the verified bundle by URL (reader-<i>.{json,png}). XCTESTRUN = the built UI-test
# .xctestrun (xcodebuild build-for-testing -scheme AntiChat-UITests -derivedDataPath build/dd). Uses the UI slot:
# refuses while another `xcodebuild … test` runs.
if [ "${READER:-0}" = 1 ]; then
  xr="${XCTESTRUN:-$(ls "$ROOT"/build/dd/Build/Products/AntiChat-UITests_*.xctestrun 2>/dev/null | head -n1)}"
  [ -f "$xr" ] || { echo "READER=1: missing XCTESTRUN (build-for-testing -scheme AntiChat-UITests)"; exit 2; }
  pgrep -f "^/Applications/Xcode[^ ]*/xcodebuild (test|test-without-building) .*UITests" >/dev/null && { echo "READER=1: another UI test run holds the UI slot"; exit 75; }
  touch "$dir/handshake"
  # The runner is sandboxed: it writes in its container's tmp; copied back below.
  rdir="$HOME/Library/Containers/app.antichat.AntiChatUITests.xctrunner/Data/tmp/at248-$(basename "$dir")"
  rm -rf "$rdir"; echo "$rdir" >"$dir/reader-dir"
  # The reader launches the app itself (by URL, foreground) with these arguments.
  echo "$APPDIR" >"$dir/launch-app"
  printf '%s\n' -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES \
    -ChatModel "$MODEL" -SearchProbe "$dir" ${EXTRA_ARGS:-} >"$dir/launch-args"
  # ATTACH=1: the script starts the app (foreground) and the reader attaches to that bundle by URL (an XCUITest
  # launch fails while another build with the same bundle id runs); default: the reader launches it. The evidence
  # build gets its own bundle id (app.antichat.AntiChat.at248, re-signed ad hoc) so no other AntiChat dev build
  # running on this Mac (hosted test suites) can collide with the launch.
  if [ "${ATTACH:-0}" = 1 ]; then
    xargs -0 env ANTICHAT_BACKGROUND=0 "$BIN" < <(tr '\n' '\0' <"$dir/launch-args") >"$dir/launch.log" 2>&1 &
  fi
  ( source "$ROOT/tools/env.sh" && cd "$ROOT" && TEST_RUNNER_ANTICHAT_AT248_ATTACH="${ATTACH:-0}" TEST_RUNNER_ANTICHAT_AT248_DIR="$dir" xcodebuild test-without-building -xctestrun "$xr" \
      -destination 'platform=macOS,arch=arm64' -resultBundlePath "$dir/reader.xcresult" \
      -only-testing:AntiChatUITests/AT248RenderedPillsUITests ) >"$dir/reader.log" 2>&1
  echo "reader exit $?"
  cp "$rdir"/reader-* "$dir/" 2>/dev/null
  while pgrep -f "$APPDIR/Contents/MacOS/AntiChat" >/dev/null; do sleep 2; done
else
"$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES \
  -ChatModel "$MODEL" -SearchProbe "$dir" ${EXTRA_ARGS:-} >"$dir/launch.log" 2>&1
echo "exit $?"
fi
uptime | sed 's/.*load/load/' >"$dir/load-after.txt"
defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
rm -rf "$box"
python3 -I - "$dir" <<'PY'
import json, statistics, sys
d = sys.argv[1]
runs = json.load(open(f"{d}/probe.json")).get("runs", [])
ok = [r for r in runs if r.get("status") == "done"]
def p50(k): v = sorted(r[k] for r in ok if r.get(k, -1) >= 0); return round(statistics.median(v), 2) if v else None
loads = [r["load_avg"][0] for r in ok if r.get("load_avg")]
s = {"runs": len(runs), "done": len(ok), "p50_complete_s": p50("complete_s"), "p50_first_token_s": p50("first_token_s"),
     "p50_activity_ms": p50("activity_ms"), "p50_settled_s": p50("settled_s"), "p50_step_s": p50("step_seconds"),
     "p50_reasoning_s": p50("reasoning_s"), "p50_answer_prompt_tokens": p50("answer_prompt_tokens"),
     "p50_answer_ttft_ms": p50("answer_ttft_ms"), "p50_answer_completion_tokens": p50("answer_completion_tokens"),
     "p50_tok_per_s": p50("tok_per_s"), "p50_tool_calls": p50("tool_calls"), "runs_with_2_pills": sum(1 for r in ok if r.get("pills_rendered", 0) >= 2),
     "load1_min_max": [round(min(loads), 1), round(max(loads), 1)] if loads else None}
# M7 at248: the rendered-pill reader's counts (AX tree of the foreground window) beside the probe's anchor counts.
import os
reader = {}
for r in runs:
    f = f"{d}/reader-{r.get('run')}.json"
    if os.path.exists(f): reader[r["run"]] = json.load(open(f))
if reader:
    s["reader_runs"] = len(reader)
    s["runs_with_2_pills_ax"] = sum(1 for r in ok if reader.get(r["run"], {}).get("pills_rendered_ax", 0) >= 2)
    s["runs_with_2_pills_both"] = sum(1 for r in ok if r.get("pills_rendered", 0) >= 2 and reader.get(r["run"], {}).get("pills_rendered_ax", 0) >= 2)
    s["runs_with_2_distinct_sources"] = sum(1 for r in ok if r.get("pill_sources_distinct", 0) >= 2)
    s["probe_ax_agree"] = sum(1 for r in ok if r.get("pills_rendered") == reader.get(r["run"], {}).get("pills_rendered_ax"))
    s["pass"] = (len(ok) == len(runs) == int(open(f"{d}/runs").read()) and (s["p50_complete_s"] or 99) <= 12
                 and s["runs_with_2_pills_both"] == len(runs))
json.dump(s, open(f"{d}/summary.json", "w"), indent=2); print(json.dumps(s))
if reader:  # the AT-248 c1 pill-count file the pass condition names
    c1 = {"at": "AT-248", "check": "c1", "evidence_dir": os.path.relpath(d, os.path.dirname(d)), "summary": s,
          "runs": [{"run": r.get("run"), "status": r.get("status"), "complete_s": r.get("complete_s"),
                    "pills_rendered_probe": r.get("pills_rendered"), "pills_rendered_ax": reader.get(r.get("run"), {}).get("pills_rendered_ax"),
                    "pills_checking_ax": reader.get(r.get("run"), {}).get("pills_checking_ax"), "pills": r.get("pills"),
                    "pill_sources_distinct": r.get("pill_sources_distinct"), "screenshot": f"reader-{r.get('run')}.png"} for r in runs]}
    json.dump(c1, open(f"{os.path.dirname(d)}/{os.path.basename(d)[:10]}-c1.json", "w"), indent=2)
PY
