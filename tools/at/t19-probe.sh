#!/bin/bash
# M1.T19 fallback runner for AT-003 / AT-010 / AT-014 / AT-299 (Q-015: XCUITest cannot enable automation mode on
# this Mac, so J02SendStreamStopTests (extended), QueueTests and SidebarStatusTests are committed but not run here).
# Runs the in-process turn probe (`-TurnProbe`, App/AntiChat/TurnProbe.swift) on build/AntiChat.app (Debug) once per
# ScriptedEngine script, each in a fresh container, offline:
#   basic        AT-010 (1)(2), AT-003 (1)(4)       tool-call    AT-003 (4) (-UseScriptedTools YES, chat-9b-q4 key)
#   stream-600w  AT-014 (1)(2), AT-010 (3)          slow-load    AT-299, AT-003 (2)
# Output: build/at/M1.T19-probe/<script>/{probe.json,*.png}; then `check <AT-ID>` prints and gates one AT's legs.
# Usage: tools/at/t19-probe.sh run            (all scripts; ~2 min)
#        tools/at/run.sh AT-010 -- tools/at/t19-probe.sh check AT-010
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/M1.T19-probe"
script_path() {
  local s="$ROOT/fixtures/scripts/$1.jsonl"
  [ -f "$s" ] && grep -q '"t":"title"' "$s" || s="$ROOT/tools/fixtures/scripts/$1.jsonl"  # staging copy (A-M1-T05a)
  echo "$s"
}
case "${1:-run}" in
run)
  [ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
  mkdir -p "$OUT"
  fail=0
  for name in basic tool-call stream-600w slow-load; do
    dir="$OUT/$name"
    box="$(mktemp -d /tmp/antichat-t19-XXXXXX)"
    rm -rf "$dir"
    args=(-ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box"
          -UseScriptedEngine "$(script_path "$name")" -FixedClock 2026-11-15T09:30:00+01:00 -TurnProbe "$dir")
    [ "$name" = tool-call ] && args+=(-UseScriptedTools YES -ChatModel chat-9b-q4)  # the 0.8B starter is chat-only (D-023)
    "$BIN" "${args[@]}" >"$box.log" 2>&1
    if [ ! -f "$dir/probe.json" ]; then echo "$name: no probe.json"; tail -20 "$box.log"; fail=1; continue; fi
    echo "$name: done"
    rm -rf "$box" "$box.log"
  done
  exit $fail
  ;;
check)
  python3 -I - "$OUT" "${2:?AT id}" <<'PY'
import json, os, sys
out, at = sys.argv[1], sys.argv[2]
legs = {
    "AT-003": [("basic", "AT-003-1"), ("slow-load", "AT-003-2"), ("basic", "AT-003-4-basic"), ("tool-call", "AT-003-4-tool")],
    "AT-010": [("basic", "AT-010-1"), ("basic", "AT-010-2"), ("stream-600w", "AT-010-3")],
    "AT-014": [("stream-600w", "AT-014-1"), ("stream-600w", "AT-014-2")],
    "AT-299": [("slow-load", "AT-299-accept"), ("slow-load", "AT-299-cancel"), ("slow-load", "AT-299-release")],
}[at]
ok, summary = True, {}
for script, leg in legs:
    p = os.path.join(out, script, "probe.json")
    data = json.load(open(p)) if os.path.exists(p) else {}
    r = data.get(leg, {"pass": False, "error": f"missing {p}"})
    summary[leg] = r
    ok = ok and bool(r.get("pass"))
    print(f"{leg} [{script}]: {'pass' if r.get('pass') else 'FAIL'}  " + json.dumps({k: v for k, v in r.items() if k != 'pass'}, sort_keys=True)[:900])
json.dump({"at": at, "form": "in-process probe (Q-015 fallback)", "pass": ok, "legs": summary},
          open(os.path.join(out, f"{at}.json"), "w"), indent=2, sort_keys=True)
print(at, "probe legs pass:", ok)
sys.exit(0 if ok else 1)
PY
  ;;
*) echo "usage: $0 run | check <AT-ID>"; exit 64 ;;
esac
