#!/bin/bash
# AT-NFR-S2 re-run (M8.T16 step 2) + journey 13 in-process (Q-015: J13CrashRecoveryTests committed, not run): a window
# chat and a quick-panel chat stream stream-600w.jsonl; the process is killed with SIGKILL mid-stream; the relaunch on
# the same container shows both replies `interrupted` with their partial text and the Retry notice. The data half
# (sweep, persister cadence) is LaunchRecoveryTests + StreamPersisterTests in the gates.
# Output: build/at/AT-NFR-S2/{stream/probe.json,probe.json}. Usage: tools/at/run.sh AT-NFR-S2 -- tools/at/at-nfr-s2-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-NFR-S2"
STREAM="$ROOT/fixtures/scripts/stream-600w.jsonl"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
rm -rf "$OUT/stream" "$OUT/probe.json"; mkdir -p "$OUT"
box=$(mktemp -d /tmp/antichat-s2-XXXXXX)
args=(-ApplePersistenceIgnoreState YES -SkipOnboarding YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$STREAM"
      -DefaultsSuite "app.antichat.s2.$$" -NotificationSpy "$OUT/requests.json" -FakePermission notifications=granted -MacIntegrationProbe "$OUT")
echo s2-stream > "$OUT/mode"
"$BIN" "${args[@]}" >"$OUT/stream.log" 2>&1 & pid=$!
for _ in $(seq 1 120); do [ -f "$OUT/stream/probe.json" ] && break; sleep 1; done
[ -f "$OUT/stream/probe.json" ] || { echo "never reached streaming"; kill -9 $pid; exit 1; }
kill -9 $pid; wait $pid 2>/dev/null
echo "killed $pid mid-stream: $(cat "$OUT/stream/probe.json" | tr -d '\n ')"
echo s2-check > "$OUT/mode"
"$BIN" "${args[@]}" >"$OUT/check.log" 2>&1 & pid=$!
for _ in $(seq 1 120); do kill -0 $pid 2>/dev/null || break; sleep 1; done
kill $pid 2>/dev/null
defaults delete "app.antichat.s2.$$" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/app.antichat.s2.$$.plist"; rm -rf "$box"
python3 -I - "$OUT" <<'PY'
import json, os, sys
o = sys.argv[1]
s = json.load(open(os.path.join(o, "stream/probe.json")))
try: c = json.load(open(os.path.join(o, "probe.json")))
except Exception as e: c = {"error": str(e)}
legs = {
    "killed-mid-stream": s.get("windowStreaming") is True and s.get("panelStreaming") is True,
    "window-chat-interrupted-partial-kept": c.get("windowChat", {}).get("status") == "interrupted" and c["windowChat"].get("chars", 0) > 0
        and c["windowChat"].get("retryShown") is True,
    "quick-panel-chat-interrupted-partial-kept": c.get("panelChat", {}).get("status") == "interrupted" and c["panelChat"].get("chars", 0) > 0,
}
ok = all(legs.values())
c.update({"at": "AT-NFR-S2", "form": "in-process kill/relaunch (journey 13, Q-015 fallback)", "pass": ok, "legs": legs, "beforeKill": s})
json.dump(c, open(os.path.join(o, "probe.json"), "w"), indent=2, sort_keys=True)
print("AT-NFR-S2 legs:", legs, "pass:", ok)
sys.exit(0 if ok else 1)
PY
