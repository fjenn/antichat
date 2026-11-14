#!/bin/bash
# AT-285 runner legs (M4.T04; R-285 AC1 + AC5 at the helper): the forced-verdict suite R241PathTraceTests
# (Packages/Engines/Tests) — one gate call per preview and per final, nothing written on block, a later blocked
# preview stops the job before its result. The seam compiles only under ANTICHAT_UI_TESTING, which no Debug/Release
# configuration defines (r241-audit rule 2b + the `nm` scan), so this builds the package once more into its OWN scratch
# path with `-DANTICHAT_UI_TESTING` (never the app's build, never build/AntiChat.app). Content-free: gradients only.
# M5.T06: + VideoGateTests and R241PathTraceTests/testVideoJobGateCalls (video final frames, I2V source unchecked);
# --no-parallel because the forced verdict is process-wide and two suites now set it. M5.T14 review: + the two
# cancel-during-check / cancel-during-encode legs of VideoGateTests (one parameterized test: 9 tests).
# Then the ordinary runner suites (MediaJobRunnerTests, MediaJobQueueTests, MediaOutputGateTests) in the normal build.
# Log: build/at/AT-285/<date>-runner.log. Exit 0 iff all pass and the forced suites actually ran their 11 tests.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/at/AT-285"; mkdir -p "$OUT"
LOG="$OUT/$(date +%F)-runner.log"
cd "$ROOT"
{
  echo "== forced-verdict build (scratch build/uitesting-spm, -DANTICHAT_UI_TESTING)"
  swift test --scratch-path build/uitesting-spm --disable-keychain --force-resolved-versions --no-parallel -Xswiftc -DANTICHAT_UI_TESTING \
    --filter 'R241PathTraceTests|VideoGateTests'
  echo "rc=$?"
  echo "== normal build"
  tools/ci/test-unit.sh 'MediaJobRunnerTests|MediaJobQueueTests|MediaOutputGateTests|VideoGateRealDetectorTests|MP4EncoderTests'
  echo "rc=$?"
} 2>&1 | tee "$LOG"
grep -q 'Test run with 11 tests in 3 suites passed' "$LOG" || { echo "at-285-runner: forced-verdict suites did not pass 11 tests (R241PathTraceTests 5 incl. edit + local jobs; VideoGateTests 6 incl. the cancel legs; the skipped real-detector suite)"; exit 1; }
[ "$(grep -c '^rc=0$' "$LOG")" = 2 ] || { echo "at-285-runner: FAILED"; exit 1; }
echo "at-285-runner: pass ($LOG)"
