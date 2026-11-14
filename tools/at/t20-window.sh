#!/bin/bash
# M1.T20 AT-090 fallback while the app cannot open a window from the agent sandbox (Q-025) and XCUITest is blocked
# (Q-015): journey 8 in-process (IncognitoJourneyWindowTests: the real MainWindow in an NSWindow of the test process,
# on-disk container hashed before/after) wrapped in tools/ci/disk-diff.py over the real ~/Library data folders, plus
# the incognito unit suites. Evidence: build/at/AT-090/{window/probe.json, window/S-07-*.png, diff.json, checks.json}.
# Usage: tools/at/run.sh AT-090 -- tools/at/t20-window.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/at/AT-090"
PHRASES="$ROOT/fixtures/prompts/copy-check/incognito-phrases.txt"
[ -f "$PHRASES" ] || PHRASES="$ROOT/tools/fixtures/staged/prompts/copy-check/incognito-phrases.txt"
rm -rf "$OUT/window"; mkdir -p "$OUT/window"
cd "$ROOT"
AT090_EVIDENCE_DIR="$OUT/window" python3 -I tools/ci/disk-diff.py run --grep-fixture "$PHRASES" --out "$OUT/diff.json" -- \
  swift test --disable-keychain --force-resolved-versions \
  --filter 'IncognitoJourneyWindowTests|IncognitoWindowTests|IncognitoGuardsTests|IncognitoStoreTests|LlamaSlotTableTests|IncognitoRequestTests'
rc=$?
python3 -I - "$OUT/window/probe.json" "$OUT/diff.json" "$OUT/checks.json" <<'PY'
import json, os, sys
probe_p, diff_p, out = sys.argv[1:4]
probe = json.load(open(probe_p)) if os.path.exists(probe_p) else {"error": "no probe.json"}
diff = json.load(open(diff_p)) if os.path.exists(diff_p) else {"pass": False}
legs = {k: v for k, v in probe.items() if isinstance(v, dict)}
for k, v in sorted(legs.items()):
    print(f"{k}: {'pass' if v.get('pass') else 'FAIL'}  " + json.dumps({a: b for a, b in v.items() if a != 'pass'}, sort_keys=True)[:600])
checks = {"windowJourney": bool(probe.get("pass")), "diskDiff": bool(diff.get("pass"))}
res = {"form": "in-process window journey + disk diff (Q-015/Q-025 fallback)", "checks": checks,
       "pending": ["fs_usage", "J08IncognitoTests (XCUITest, Q-015)"], "pass": all(checks.values())}
json.dump(res, open(out, "w"), indent=2, sort_keys=True)
print("window journey + disk diff pass:", res["pass"], "| pending:", res["pending"])
sys.exit(0 if res["pass"] else 1)
PY
crc=$?
[ $rc -eq 0 ] && [ $crc -eq 0 ]
