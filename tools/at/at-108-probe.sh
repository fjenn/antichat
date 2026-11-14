#!/bin/bash
# AT-108 / AT-042 fallback runner (M8.T12; Q-015: XCUITest cannot start here, so NotificationsUITests and
# VideoBackgroundUITests are committed but not run). Runs the in-process MacIntegrationProbe on build/AntiChat.app
# (Debug, background run: the app is never active, so it is "unfocused" for the notification policy) with the
# notification spy (`-NotificationSpy`: requests recorded, nothing delivered) and faked notification permission
# (`-FakePermission`: no TCC), one fresh container + Defaults suite per mode:
#   notifications/  notifications=notDetermined: explainer → Allow → answer request; Never / Responses off / Always +
#                   sound; download; click → chat + message + flash                                     (AT-108 AC1–AC2)
#   denied/         notifications=denied: no request; Settings banner; Open System Settings → pane URL  (AT-108 AC2)
#   video/          video-kind job via the generic queue: progress across a chat switch, Dock badge, last window
#                   closing keeps the app, one `video` request at its end, ⌘Q → Wait → quits by itself  (AT-042)
# Output: build/at/AT-108/<mode>/{probe.json,requests.json}, build/at/AT-108/probe.json (+ AT-042/probe.json).
# Usage: tools/at/run.sh AT-108 -- tools/at/at-108-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-108"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT (fixtures submodule)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT" "$ROOT/build/at/AT-042"
fail=0
launch() {  # <mode> <permission> [engine args…]
  local mode=$1 perm=$2 limit=180; shift 2
  local dir="$OUT/$mode" box
  rm -rf "$dir"; mkdir -p "$dir"; echo "$mode" > "$dir/mode"
  box=$(mktemp -d /tmp/antichat-at108-XXXXXX)
  "$BIN" -ApplePersistenceIgnoreState YES -SkipOnboarding YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" \
    "$@" -DefaultsSuite "app.antichat.at108.$mode.$$" -NotificationSpy "$dir/requests.json" \
    -FakePermission "notifications=$perm" -MacIntegrationProbe "$dir" >"$dir/app.log" 2>&1 &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt $limit ]; do sleep 1; t=$((t+1)); done
  if kill -0 $pid 2>/dev/null; then echo "$mode: still running after ${limit}s"; kill $pid; fail=1; fi
  echo "$t" > "$dir/exit-after-s"
  defaults delete "app.antichat.at108.$mode.$$" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/app.antichat.at108.$mode.$$.plist"
  rm -rf "$box"
  [ -f "$dir/probe.json" ] || { echo "$mode: no probe.json"; tail -20 "$dir/app.log"; fail=1; }
}
MODES=${MODES:-notifications denied video}  # a subset re-runs only those (the summary reads every mode's last probe.json)
for m in $MODES; do
  case $m in
    notifications) launch notifications notDetermined -UseScriptedEngine "$SCRIPT" ;;
    denied) launch denied denied -UseScriptedEngine "$SCRIPT" ;;
    video) launch video granted ;;  # the XPC helper runs the scripted media job (`scripted:<steps>:<ms>` model)
  esac
done
python3 -I - "$OUT" "$ROOT/build/at/AT-042" <<'PY' || fail=1
import json, os, sys
o, o42 = sys.argv[1], sys.argv[2]
def load(n, f="probe.json"):
    try: return json.load(open(os.path.join(o, n, f)))
    except Exception as e: return {"error": str(e)}
n, d, v = load("notifications"), load("denied"), load("video")
reqs = load("video", "requests.json")
reqs = reqs if isinstance(reqs, list) else []
f = n.get("first", {})
legs108 = {
    "0-nothing-asked-at-launch": n.get("stepsAtLaunch") == [] and n.get("appActive") is False,
    "1-explainer-before-request": n.get("explainerShown") is True and n.get("requestsBeforeAllow") == 0
        and n.get("stepsAfterFirst") == ["explained:notifications", "requested:notifications"] and n.get("explainerGone") is True,
    "1-answer-request": f.get("category") == "answer" and f.get("body", "").endswith(": reply ready")
        and f.get("threadID") == n.get("firstChatID") != "" and f.get("userInfo", {}).get("messageID") == n.get("firstReplyID") != "",
    "2-never-and-category-off": n.get("neverAdded") == 0 and n.get("responsesOffAdded") == 0,
    "2-always-and-sound": n.get("alwaysAdded") == 1 and n.get("soundRequest", {}).get("sound") == "Submarine.aiff",
    "3-download": n.get("download", {}).get("category") == "download" and n.get("download", {}).get("body") == "Photo is ready",
    "4-click-opens-at-result": n.get("click", {}) == {"opened": True, "revealed": True, "flashOnScreen": True, "flashEnds": True},
    "5-denied-banner-and-fix": d.get("status") == "denied" and d.get("bannerShown") is True and d.get("requests") == 0
        and d.get("steps") == ["openedSettings:notifications"]
        and d.get("fixURL") == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.antichat.AntiChat"
        and open(os.path.join(o, "denied", "opened-urls.txt")).read().strip() == d.get("fixURL"),
}
vid = [r for r in reqs if r.get("category") == "video"]
first_state = v.get("firstJobState")
want_body = "Your video is ready" if first_state == "done" else "Your video didn't finish."
quit = v.get("quit", {})
exit_after = int(open(os.path.join(o, "video", "exit-after-s")).read().strip() or 999)
legs042 = {
    "1-navigate-away-keeps-job": v.get("tracked") == "video" and v.get("progressAfterNavigate", {}).get("advanced") is True
        and v.get("progressAfterNavigate", {}).get("stillRunning") is True,
    "2-end-notifies-once": len(v.get("videoRequests", [])) == 1 and v["videoRequests"][0].get("body") == want_body
        and v["videoRequests"][0].get("userInfo", {}).get("chatID", "") != "",
    "3-window-close-keeps-app": v.get("terminateAfterLastWindowWhileJob") is False and v.get("terminateAfterLastWindowIdle") is True,
    "3-dock-badge": v.get("dockBadgeWhileRunning") == "1" and v.get("dockBadgeAfter") == "",
    "3-quit-asks-wait-then-quits": quit.get("asked") == "video" and quit.get("waiting") is True and quit.get("jobStillRunning") is True
        and quit.get("toast") == "AntiChat will quit when the video is done." and quit.get("requestsBeforeQuit") == 1
        and len(vid) == 2 and exit_after < 170,
}
for name, legs, path in (("AT-108", legs108, o), ("AT-042", legs042, o42)):
    ok = all(legs.values())
    json.dump({"at": name, "form": "in-process probe (Q-015 fallback)", "pass": ok, "legs": legs,
               "firstJobState": first_state if name == "AT-042" else None},
              open(os.path.join(path, "probe.json"), "w"), indent=2, sort_keys=True)
    print(name, "legs:", json.dumps(legs, indent=1), "pass:", ok)
print("outcomes:", n.get("outcomes"))
sys.exit(0 if all(legs108.values()) and all(legs042.values()) else 1)
PY
exit $fail
