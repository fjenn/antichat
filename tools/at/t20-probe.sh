#!/bin/bash
# M1.T20 runner for AT-090 / AT-NFR-PR3 (Q-015: XCUITest cannot enable automation mode on this Mac, so
# App/UITests/J08IncognitoTests.swift is committed but not run here). Runs the in-process incognito probe
# (`-IncognitoProbe`, App/AntiChat/IncognitoProbe.swift) on build/AntiChat.app (Debug) inside tools/ci/disk-diff.py:
# the probe does its on-disk setup, signals `ready`, the runner snapshots ~/Library/{Application Support,Caches,Logs,
# Saved Application State}/AntiChat*|app.antichat*, then the probe runs journey 8 (3 turns incl. a 12k paste card
# and a regenerate, close confirmation, quit) and the runner diffs + greps for the fixture phrases.
#   scripted  AT-090: in-process ScriptedEngine (regen.jsonl), the fast form
#   real      AT-NFR-PR3: the real XPC helper + MLX `chat-0.8b` (`min` models), run under the GPU lock
# The dev container lives under ~/Library/Application Support/AntiChat-T20-<pid> (inside the diff scope; the real
# mode's dev model cache too). Other AntiChat* folders there are other tracks' (disk-diff.py --own).
# T20_TIMEOUT (s, default 2400): ad-hoc builds can sit in launch verification for ~10 min on this Mac.
# Output: build/at/<AT-ID>/{probe/,diff.json}; then the checks below gate the AT.
# Usage: tools/at/run.sh AT-090 -- tools/at/t20-probe.sh scripted
#        tools/at/run.sh AT-NFR-PR3 -- lockf /tmp/antichat-gpu.lock tools/at/t20-probe.sh real
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-scripted}"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
case "$MODE" in
  scripted) AT=AT-090 ;;
  real) AT=AT-NFR-PR3 ;;
  *) echo "usage: $0 scripted|real"; exit 64 ;;
esac
OUT="$ROOT/build/at/$AT"
PROBE="$OUT/probe"
PHRASES="$ROOT/fixtures/prompts/copy-check/incognito-phrases.txt"
[ -f "$PHRASES" ] || PHRASES="$ROOT/tools/fixtures/staged/prompts/copy-check/incognito-phrases.txt"  # staging copy
SCRIPT="$ROOT/fixtures/scripts/regen.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/regen.jsonl"
BOX="$HOME/Library/Application Support/AntiChat-T20-$$"
rm -rf "$PROBE" "$OUT/diff.json" "$OUT/checks.json"; mkdir -p "$PROBE"  # no stale results from an earlier run
cp "$PHRASES" "$PROBE/phrases.txt"
args=(-ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$BOX" -IncognitoProbe "$PROBE"
      -NotificationSpy "$PROBE/requests.json" -FakePermission notifications=granted)  # M8.T16: notifications present
if [ "$MODE" = scripted ]; then
  args+=(-UseScriptedEngine "$SCRIPT")
else
  args+=(-UseScriptedEngine NO -ChatModel chat-0.8b)
  # M8.T16 isolation: the run reads chat-0.8b from its own dev model cache inside $BOX (APFS clones of the shared
  # install, no extra disk), never from the shared AntiChat-Dev/Models that other tracks download into.
  SHARED_MODELS="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
  SHARED_MODELS="${SHARED_MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
  [ -d "$SHARED_MODELS/installs/chat-0.8b" ] || { echo "missing chat-0.8b (make models-dev TIER=min)"; exit 2; }
  mkdir -p "$BOX/DevCache/Models/installs"
  cp -cRL "$SHARED_MODELS/installs/chat-0.8b" "$BOX/DevCache/Models/installs/chat-0.8b"
  export ANTICHAT_DEV_CACHE="$BOX/DevCache"
fi
# --own: other AntiChat* folders under Application Support are other tracks' (reported, phrase-grepped, not failed).
python3 -I "$ROOT/tools/ci/disk-diff.py" run --grep-fixture "$PHRASES" --out "$OUT/diff.json" --own "$BOX" \
  --ready "$PROBE/ready" --go "$PROBE/go" --timeout "${T20_TIMEOUT:-2400}" -- "$BIN" "${args[@]}"
diff_rc=$?
python3 -I - "$PROBE/probe.json" "$OUT/diff.json" "$OUT/checks.json" "$BOX" <<'PY'
import json, os, sys
probe_p, diff_p, out, box = sys.argv[1:5]
probe = json.load(open(probe_p)) if os.path.exists(probe_p) else {"error": "no probe.json"}
diff = json.load(open(diff_p)) if os.path.exists(diff_p) else {"pass": False, "error": "no diff.json"}
legs = {k: v for k, v in probe.items() if k.startswith("AT-")}
quit_tmp = (legs.get("AT-090-4-quit") or {}).get("tempDir", "")
first_tmp = (legs.get("AT-090-2-journey") or {}).get("tempDir", "")
checks = {
    "probe": bool(probe.get("pass")),
    "diskDiff": bool(diff.get("pass")),
    "tempDirsGoneAfterQuit": bool(quit_tmp) and not os.path.exists(quit_tmp) and bool(first_tmp) and not os.path.exists(first_tmp),
}
for k, v in sorted(legs.items()):
    print(f"{k}: {'pass' if v.get('pass') else 'FAIL'}  " + json.dumps({a: b for a, b in v.items() if a != 'pass'}, sort_keys=True)[:700])
print("disk diff:", "pass" if checks["diskDiff"] else "FAIL", f"({len(diff.get('violations', []))} violations,",
      f"{len(diff.get('entries', []))} entries)")
print("temp dirs gone after quit:", checks["tempDirsGoneAfterQuit"])
res = {"form": "in-process probe + disk diff (Q-015 fallback)", "checks": checks, "legs": legs,
       "pending": ["fs_usage"], "pass": all(checks.values())}
json.dump(res, open(out, "w"), indent=2, sort_keys=True)
print("probe legs + disk diff pass:", res["pass"], "(fs_usage leg pending: needs sudo)")
sys.exit(0 if res["pass"] else 1)
PY
rc=$?
rm -rf "$BOX"
[ $diff_rc -eq 0 ] && [ $rc -eq 0 ]
