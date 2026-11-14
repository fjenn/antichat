#!/bin/bash
# AT-009 fallback runner (M1.T18; Q-015: XCUITest cannot enable automation mode on this Mac, so ContextTests is
# committed but not run here). Runs the in-process context probe (`-ContextProbe`, App/AntiChat/ContextProbe.swift)
# on build/AntiChat.app (Debug) with the ScriptedEngine `long-context.jsonl` and `-FakeContextWindow 4096`:
#   default/   no -showContextUsage: leg (1) "hidden by default" (one turn, indicator not on screen);
#   enabled/   -showContextUsage YES: leg (1) rising percentage (± 2 pts of an independent chars/4 estimate),
#              leg (2) the summary notice once + expanded rows, leg (3) the oversize prompt refused.
# Output: build/at/AT-009/{default,enabled}/{probe.json,*.png}, build/at/AT-009/probe.json (both runs + pass).
# Usage: tools/at/run.sh AT-009 -- tools/at/at-009-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-009"
SCRIPT="$ROOT/fixtures/scripts/long-context.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/long-context.jsonl"  # staging copy (A-M1-T05a)
[ -f "$SCRIPT" ] || { echo "missing long-context.jsonl (python3 -I tools/fixtures/gen-scripts.py)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
for mode in default enabled; do
  dir="$OUT/$mode"
  box="$(mktemp -d /tmp/antichat-at009-XXXXXX)"
  rm -rf "$dir"
  args=(-ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT"
        -FakeContextWindow 4096 -ContextProbe "$dir")
  [ "$mode" = enabled ] && args+=(-showContextUsage YES)
  "$BIN" "${args[@]}" >"$box.log" 2>&1
  if [ ! -f "$dir/probe.json" ]; then echo "$mode: no probe.json"; tail -20 "$box.log"; fail=1; continue; fi
  rm -rf "$box" "$box.log"
done
python3 -I - "$OUT" <<'PY' || fail=1
import json, os, sys
o = sys.argv[1]
d = json.load(open(os.path.join(o, "default", "probe.json")))
e = json.load(open(os.path.join(o, "enabled", "probe.json")))
legs = {
    "1a-hidden-by-default": d.get("leg1", {}).get("pass", False),
    "1b-rises-within-2pts": e.get("leg1", {}).get("pass", False),
    "2-summarised-notice-once-expands": e.get("leg2", {}).get("pass", False),
    "3-oversize-refused-no-request": e.get("leg3", {}).get("pass", False),
}
for t in e.get("turns", []):
    print(f"turn {t['turn']}: {t['percent']}% (unclamped {t['percentUnclamped']}%, independent {t['independentPercent']}%) notices={t['noticesInThread']} summaries={t['summaryRows']} "
          f"requests={t['engineRequests']}")
print("leg2:", {k: v for k, v in e.get("leg2", {}).items() if k != "summaryRows"})
print("leg3:", e.get("leg3"))
ok = all(legs.values())
json.dump({"at": "AT-009", "form": "in-process probe (Q-015 fallback)", "pass": ok, "legs": legs,
           "default": d, "enabled": e}, open(os.path.join(o, "probe.json"), "w"), indent=2, sort_keys=True)
print("legs:", legs, "pass:", ok)
sys.exit(0 if ok else 1)
PY
exit $fail
