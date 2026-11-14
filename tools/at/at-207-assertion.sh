#!/bin/bash
# AT-207 AC5 (M2.T14): the power assertion during generation / downloads is visible to `pmset -g assertions` and gone
# after. Runs PowerAssertionTests (which also read the assertions back with IOPMCopyAssertionsByProcess) while
# sampling `pmset -g assertions` every 0.2 s; passes when an "AntiChat is generating" PreventUserIdleSystemSleep line
# was seen during the run and none is left 5 s after it. Log: build/at/AT-207/assertion.log.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/at/AT-207"; mkdir -p "$OUT"; LOG="$OUT/assertion.log"; : > "$LOG"
( while true; do pmset -g assertions | grep -i "AntiChat is" >> "$LOG.samples"; sleep 0.2; done ) &
SAMPLER=$!
(cd "$ROOT" && make test-unit FILTER=PowerAssertionTests) > "$OUT/assertion-tests.log" 2>&1
RC=$?
sleep 5
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
SEEN=$(grep -c "AntiChat is generating" "$LOG.samples" 2>/dev/null || true)
LEFT=$(pmset -g assertions | grep -c "AntiChat is generating")
rm -f "$LOG.samples"
echo "tests rc=$RC, pmset lines with 'AntiChat is generating' during the run: $SEEN, 5 s after: $LEFT" | tee "$LOG"
[ "$RC" = 0 ] && [ "${SEEN:-0}" -gt 0 ] && [ "$LEFT" = 0 ] && exit 0 || exit 1
