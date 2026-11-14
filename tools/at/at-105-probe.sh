#!/bin/bash
# AT-105 / AT-106 fallback runner (M8.T13; Q-015: MenuBarUITests and QuickPanelUITests are committed, not run).
# Runs the in-process MacIntegrationProbe on build/AntiChat.app (Debug, background run: the panel and the menu are
# exercised without taking focus from the owner), one fresh container + Defaults suite per mode:
#   menubar/     no scripted chat engine (the XPC helper runs a scripted `video` job): default item, menu order,
#                progress rows + busy icon, every action, Off removes it, Quit AntiChat quits        (AT-105)
#   quickpanel/  stream-600w.jsonl: hidden panel at launch, open (floating / non-activating / all Spaces / focused),
#                Return streams, Esc hides while streaming, collapse-then-hide, ⌘O hands the same conversation to the
#                main window, recorder other combo / Off, 20 in-process open times                     (AT-106)
# The NFR-U9 number itself comes from `make perf METRIC=U9` (tools/perf/run.py probe_u9) under gpu-run.sh timing.
# Output: build/at/AT-105/<mode>/probe.json, build/at/AT-105/probe.json, build/at/AT-106/probe.json.
# Usage: tools/at/run.sh AT-105 -- tools/at/at-105-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-105"
STREAM="$ROOT/fixtures/scripts/stream-600w.jsonl"
[ -f "$STREAM" ] || { echo "missing $STREAM (fixtures submodule)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT" "$ROOT/build/at/AT-106"
fail=0
launch() {  # <mode> [args…]
  local mode=$1 limit=240; shift
  local dir="$OUT/$mode" box
  rm -rf "$dir"; mkdir -p "$dir"; echo "$mode" > "$dir/mode"
  box=$(mktemp -d /tmp/antichat-at105-XXXXXX)
  "$BIN" -ApplePersistenceIgnoreState YES -SkipOnboarding YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" "$@" \
    -DefaultsSuite "app.antichat.at105.$mode.$$" -NotificationSpy "$dir/requests.json" -FakePermission "notifications=granted" \
    -MacIntegrationProbe "$dir" >"$dir/app.log" 2>&1 &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt $limit ]; do sleep 1; t=$((t+1)); done
  if kill -0 $pid 2>/dev/null; then echo "$mode: still running after ${limit}s"; kill $pid; fail=1; fi
  echo "$t" > "$dir/exit-after-s"
  defaults delete "app.antichat.at105.$mode.$$" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/app.antichat.at105.$mode.$$.plist"
  rm -rf "$box"
  [ -f "$dir/probe.json" ] || { echo "$mode: no probe.json"; tail -20 "$dir/app.log"; fail=1; }
}
MODES=${MODES:-menubar quickpanel}
for m in $MODES; do
  case $m in
    menubar) launch menubar ;;
    quickpanel) launch quickpanel -UseScriptedEngine "$STREAM" ;;
  esac
done
python3 -I - "$OUT" "$ROOT/build/at/AT-106" <<'PY' || fail=1
import json, os, sys
o, o106 = sys.argv[1], sys.argv[2]
def load(n):
    try: return json.load(open(os.path.join(o, n, "probe.json")))
    except Exception as e: return {"error": str(e)}
m, q = load("menubar"), load("quickpanel")
idle = ["New Chat", "Quick Panel", "Start Voice", "—", "Open AntiChat", "Quit AntiChat"]
busy = m.get("busyMenu", [])
exit_m = int(open(os.path.join(o, "menubar", "exit-after-s")).read().strip() or 999)
legs105 = {
    "1-on-by-default": m.get("insertedByDefault") is True and m.get("iconTemplate") is True and m.get("idleIcon") == "idle",
    "1-menu-order": m.get("idleMenu") == idle and "⌥Space" in m.get("idleShortcuts", []),
    "1-voice-reason-without-pack": m.get("voiceEnabled") is False and "Install Voice to use this" in m.get("idleSubtitles", []),
    "1-progress-rows-and-dot": busy[:4] == idle[:4] and "Photo 42%" in busy and any(t.startswith("Video") for t in busy)
        and busy[-3:] == idle[-3:] and m.get("busyIcon") == "busy",
    "1-actions": m.get("newChat") is True and m.get("quickPanel") is True and m.get("openApp") is True and m.get("jobRowOpensChat") is True,
    "1-toggle-off-removes": m.get("removedWhenOff") is True and m.get("backWhenOn") is True,
    "1-quit-quits": m.get("quit") == "started" and exit_m < 230,
}
op, se, esc, cth, oa, rec = q.get("open", {}), q.get("send", {}), q.get("escWhileStreaming", {}), q.get("escCollapseThenHide", {}), q.get("openInApp", {}), q.get("recorder", {})
legs106 = {
    "1-prepared-hidden": q.get("preparedHidden") is True,
    "0-no-focus-taken": q.get("backgroundRun") is True and q.get("appActiveBefore") is False and op.get("appActive") is False,
    "1-floating-composer-above-all": op.get("visible") is True and op.get("floating") is True and op.get("nonActivating") is True
        and op.get("allSpaces") is True and op.get("fullScreenAux") is True and op.get("fieldFocused") is True and op.get("size") == "640x120",
    "1-return-streams-in-panel": se.get("streamed") is True and se.get("size") == "640x480" and se.get("replyOnScreen") is True and se.get("rowInDB") is True,
    "1-esc-while-streaming-hides-answer-continues": esc == {"wasStreaming": True, "hidden": True} and q.get("finishedInBackground") is True,
    "1-esc-collapses-then-hides": cth.get("first") == "collapsedReply" and cth.get("visibleAfterFirst") is True
        and cth.get("sizeAfterFirst") == "640x120" and cth.get("second") == "hidePanel" and cth.get("hiddenAfterSecond") is True
        and q.get("reopenFresh") is True,
    "1-open-in-app-continues": oa.get("streamingAtHandoff") is True and oa.get("opened") is True and oa.get("sameConversation") is True
        and oa.get("panelHidden") is True and oa.get("mainReplyComplete") is True and oa.get("mainStatus") == "done",
    "1-configurable-or-off": rec.get("other") == "⌃⌥Q" and rec.get("offIsNil") is True and rec.get("conflictWhenOff") is False
        and q.get("defaultBack") == "⌥Space",
}
for name, legs, path in (("AT-105", legs105, o), ("AT-106", legs106, o106)):
    ok = all(legs.values())
    json.dump({"at": name, "form": "in-process probe (Q-015 fallback)", "pass": ok, "legs": legs,
               "openMs_inprocess": q.get("openMs") if name == "AT-106" else None},
              open(os.path.join(path, "probe.json"), "w"), indent=2, sort_keys=True)
    print(name, "legs:", json.dumps(legs, indent=1), "pass:", ok)
print("in-process open ms (Debug, background):", q.get("openMs"))
sys.exit(0 if all(legs105.values()) and all(legs106.values()) else 1)
PY
exit $fail
