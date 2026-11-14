#!/bin/bash
# AT-100 / AT-062 / AT-011 leg (4) / AT-012 leg (2) fallback runner (M1.T22; Q-015: XCUITest cannot enable
# automation mode on this Mac, so J10SettingsTests / ArchivedChatsTests / J09 (2) are committed but not run here).
# Runs the in-process Settings probe (`-SettingsProbe`, App/AntiChat/SettingsProbe.swift) on build/AntiChat.app
# (Debug) with a throwaway container and a throwaway Defaults suite (the developer's settings are never touched):
#   full/        the full run: ⌘, + nav order + search, every M1 row changed once, footer menu, Advanced collapsed,
#                Archived chats / Archive all / Delete all, ⌘K row → Settings at that row, the composer and the
#                context indicator following the toggled settings (AT-002 (4)–(5), AT-009 (1) via the UI);
#   full/ again  relaunch on the same suite: every value read back after relaunch (relaunch.json);
#   launchargs/  a fresh suite with `-sendWithCommandEnter YES -plainTextComposer YES -showContextUsage YES`
#                (step 8: Bool launch overrides read as booleans, nothing written to disk).
# Output: build/at/AT-100/{full,launchargs}/…, build/at/AT-100/probe.json (all runs + pass per AT).
# Usage: tools/at/run.sh AT-100 -- tools/at/at-100-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-100"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"  # staging copy (A-M1-T05a)
[ -f "$SCRIPT" ] || { echo "missing basic.jsonl (python3 -I tools/fixtures/gen-scripts.py)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
stamp="$(date +%s)"
fail=0

launch() {  # <dir> <suite> [extra args…]
  local dir=$1 suite=$2; shift 2
  local box; box="$(mktemp -d /tmp/antichat-at100-XXXXXX)"
  "$BIN" -ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" \
    -UseScriptedEngine "$SCRIPT" -DefaultsSuite "$suite" -SettingsProbe "$dir" "$@" >"$box.log" 2>&1 &
  local pid=$!
  ( sleep 240; kill "$pid" 2>/dev/null ) &  # watchdog: a stuck probe never blocks the run
  local dog=$!
  wait "$pid"
  kill "$dog" 2>/dev/null
  if [ ! -f "$dir/probe.json" ]; then echo "$dir: no probe.json"; tail -20 "$box.log"; fail=1; fi
  rm -rf "$box" "$box.log"
}

suite="com.antichat.at100.$stamp"
rm -rf "$OUT/full" "$OUT/launchargs"
mkdir -p "$OUT/full" "$OUT/launchargs"
launch "$OUT/full" "$suite"
[ -f "$OUT/full/probe.json" ] && mv "$OUT/full/probe.json" "$OUT/full/full.json"
launch "$OUT/full" "$suite"  # written.json present → relaunch verification
[ -f "$OUT/full/probe.json" ] && mv "$OUT/full/probe.json" "$OUT/full/relaunch.json"
defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
suite2="com.antichat.at100.args.$stamp"
launch "$OUT/launchargs" "$suite2" -sendWithCommandEnter YES -plainTextComposer YES -showContextUsage YES
defaults delete "$suite2" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite2.plist"
rm -f "$HOME/Library/Preferences/$suite.plist" "$HOME/Library/Preferences/$suite2.plist"

python3 -I - "$OUT" <<'PY' || fail=1
import json, os, sys
o = sys.argv[1]
def load(p):
    try:
        return json.load(open(os.path.join(o, p)))
    except Exception as e:
        return {"pass": False, "error": str(e)}
full, rel, args = load("full/full.json"), load("full/relaunch.json"), load("launchargs/probe.json")
L = full.get("legs", {})
def ok(k): return L.get(k, {}).get("pass", False)
ats = {
    "AT-100": {"1-open-nav-search": ok("AT-100-1"), "2-instant-save": ok("AT-100-2"),
               "2-after-relaunch": rel.get("pass", False), "3-footer-menu": ok("AT-100-3"),
               "4-advanced-collapsed": ok("AT-100-4")},
    "AT-062": {"1-3000-limit": ok("AT-062-1"), "2-prompt-layer": ok("AT-062-2")},
    "AT-011": {"4-archived-chats": ok("AT-011-4")},
    "AT-012": {"2-settings-at-row": ok("AT-012-2")},
    "convention-9": {"ui-toggles (AT-002 4-5, AT-009 1)": ok("UI-toggles"),
                     "launch-arguments (step 8)": args.get("pass", False)},
}
for at, legs in ats.items():
    print(at, legs)
for k, v in L.items():
    print(k, {a: b for a, b in v.items() if a not in ("expected", "read", "methods")})
print("relaunch:", {k: v for k, v in rel.items() if k != "read"})
print("launchargs:", args.get("legs"))
passed = all(all(v.values()) for v in ats.values())
json.dump({"form": "in-process probe (Q-015 fallback)", "pass": passed, "ats": ats, "full": full,
           "relaunch": rel, "launchargs": args}, open(os.path.join(o, "probe.json"), "w"), indent=2, sort_keys=True)
print("pass:", passed)
sys.exit(0 if passed else 1)
PY
exit $fail
