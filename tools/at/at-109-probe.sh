#!/bin/bash
# AT-109 fallback runner (M8.T14; Q-015: JITPermissionsUITests is committed, not run). Three parts:
#   1. `tools/ci/permission-calls.py`: every system permission request is in PermissionCoordinator, onboarding names
#      no requester, the vendored request paths are unreachable (0 violations).
#   2. MacIntegrationProbe modes on build/AntiChat.app (Debug, background run, faked TCC states, scripted voice so
#      no microphone is ever opened):
#        jit/         microphone, location, notifications notDetermined: nothing at launch; mic → explainer sheet →
#                     Continue → request; location switch → explainer → Continue → request (step log order)
#        jit-denied/  all denied: the mic's denied popover (no request), the location notice + Open System Settings,
#                     the inline fix of each kind names its pane
#      + the notifications leg from AT-108 (build/at/AT-108/notifications: explainer before the request, first event).
#   3. The unified log: TCC requests by the dev bundle during this run (Microphone, ScreenCapture, Accessibility,
#      ListenEvent, SpeechRecognition, Location) = 0 — no live dialog anywhere, Screen Recording never requested.
# Output: build/at/AT-109/{lint.txt,<mode>/probe.json,tcc.txt,probe.json}.
# Usage: tools/at/run.sh AT-109 -- tools/at/at-109-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-109"
VOICE="$ROOT/fixtures/voice/scripts/dictation-anatomy.jsonl"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$ROOT/build/AntiChat.app/Contents/Info.plist")
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
[ -f "$VOICE" ] || { echo "missing $VOICE (fixtures submodule)"; exit 2; }
mkdir -p "$OUT"
fail=0
since=$(date "+%Y-%m-%d %H:%M:%S")
python3 -I "$ROOT/tools/ci/permission-calls.py" > "$OUT/lint.txt" 2>&1 || fail=1
cat "$OUT/lint.txt"
launch() {  # <mode> <fake states>
  local mode=$1 fakes=$2 limit=180
  local dir="$OUT/$mode" box
  rm -rf "$dir"; mkdir -p "$dir"; echo "$mode" > "$dir/mode"
  box=$(mktemp -d /tmp/antichat-at109-XXXXXX)
  "$BIN" -ApplePersistenceIgnoreState YES -SkipOnboarding YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" \
    -UseScriptedEngine "$SCRIPT" -UseScriptedVoice "$VOICE" -FakeVoiceInstalled YES -FakePackState voice=ready \
    -DefaultsSuite "app.antichat.at109.$mode.$$" -NotificationSpy "$dir/requests.json" -FakePermission "$fakes" \
    -MacIntegrationProbe "$dir" >"$dir/app.log" 2>&1 &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt $limit ]; do sleep 1; t=$((t+1)); done
  if kill -0 $pid 2>/dev/null; then echo "$mode: still running after ${limit}s"; kill $pid; fail=1; fi
  defaults delete "app.antichat.at109.$mode.$$" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/app.antichat.at109.$mode.$$.plist"
  rm -rf "$box"
  [ -f "$dir/probe.json" ] || { echo "$mode: no probe.json"; tail -20 "$dir/app.log"; fail=1; }
}
launch jit "microphone=notDetermined,location=notDetermined,notifications=notDetermined"
launch jit-denied "microphone=denied,location=denied,notifications=denied"
sleep 2
: > "$OUT/tcc.txt"
for svc in kTCCServiceMicrophone kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServiceListenEvent \
           kTCCServiceSpeechRecognition kTCCServiceLocation; do
  "$ROOT/tools/ci/tcc-requests.sh" "$BUNDLE" "$since" "$svc" 2>/dev/null >> "$OUT/tcc.txt" || echo "$svc requests=?" >> "$OUT/tcc.txt"
done
cat "$OUT/tcc.txt"
python3 -I - "$OUT" "$ROOT/build/at/AT-108/notifications/probe.json" <<'PY' || fail=1
import json, os, re, sys
o, n108 = sys.argv[1], sys.argv[2]
def load(n):
    try: return json.load(open(os.path.join(o, n, "probe.json")))
    except Exception as e: return {"error": str(e)}
j, d = load("jit"), load("jit-denied")
try: n = json.load(open(n108))
except Exception as e: n = {"error": str(e)}
lint = open(os.path.join(o, "lint.txt")).read()
tcc = dict(re.findall(r"(kTCCService\w+) requests=(\S+)", open(os.path.join(o, "tcc.txt")).read()))
panes = {"microphone": "Privacy_Microphone", "location": "Privacy_LocationServices",
         "notifications": "com.apple.Notifications-Settings.extension"}
legs = {
    "lint-0-violations": "permission-calls: 0 violation(s)" in lint,
    "1-nothing-at-launch": j.get("atLaunch") == {"steps": [], "micRequests": 0, "locationRequests": 0}
        and d.get("atLaunch") == {"steps": [], "micRequests": 0, "locationRequests": 0},
    "1-mic-on-first-use-after-explainer": j.get("micButton") is True and j.get("micExplainer") is True
        and j.get("micRequestsBeforeContinue") == 0 and j.get("micRequests") == 1 and j.get("micStatus") == "granted",
    "1-location-on-enable-after-explainer": j.get("locationRow") is True and j.get("locationExplainer") is True
        and j.get("locationRequestsBeforeContinue") == 0 and j.get("locationRequests") == 1
        and j.get("locationStatus") in ("notDetermined", "granted"),  # the faked macOS dialog stays unanswered (LocationSystem.fake)
    "1-notifications-on-first-event-after-explainer": n.get("stepsAtLaunch") == []
        and n.get("stepsAfterFirst") == ["explained:notifications", "requested:notifications"],
    "2-explainer-before-every-request": j.get("requestedWithoutExplainer") == [] and d.get("requestedWithoutExplainer") == []
        and j.get("steps") == ["explained:microphone", "requested:microphone", "explained:location", "requested:location"],
    "2-denied-inline-fixes": d.get("micDeniedPopover") is True and d.get("micRequests") == 0 and d.get("locationFix") is True
        and all(panes[k] in d.get("fixes", {}).get(k, "") for k in panes),
    "3-no-live-tcc-request-incl-screen-recording": bool(tcc) and all(v == "0" for v in tcc.values()),
}
ok = all(legs.values())
json.dump({"at": "AT-109", "form": "lint + in-process probe + unified log (Q-015 fallback)", "pass": ok, "legs": legs, "tcc": tcc},
          open(os.path.join(o, "probe.json"), "w"), indent=2, sort_keys=True)
print("AT-109 legs:", json.dumps(legs, indent=1), "pass:", ok)
sys.exit(0 if ok else 1)
PY
exit $fail
