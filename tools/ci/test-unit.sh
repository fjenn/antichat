#!/bin/bash
# make test-unit runner with a failure guard (M1.T24 follow-up). `swift test --parallel` has exited 0 although tests
# failed: the UI module's test process could end mid-run with status 0 (a CFRunLoopStop on the main run loop ends
# Swift Testing's main loop before it prints its summary), and its failures were then lost. A run passes only if
#   1. every `swift test` invocation exits 0,
#   2. the console shows no failed test / suite / run (Swift Testing ✘ lines, XCTest "error:" / "failed" lines),
#   3. every Swift Testing run that started printed its end-of-run summary ("Test run with N tests … passed"),
#   4. the xUnit reports record no failures or errors.
# Usage: tools/ci/test-unit.sh [filter]     (log + xunit under build/test-unit/)
# Self-test: tools/ci/test-unit.sh --selftest (a deliberate failure and a silent exit(0) must both be caught).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/test-unit"
mkdir -p "$OUT"

# check <log> <xunit-glob…>: the guard proper; prints why and returns 1 on any failure sign.
check() {
  local log=$1; shift
  local bad=0
  if grep -aE '^✘ |✘ (Test|Suite)|Test run with .* failed|: error: -\[|Executed .* with [1-9][0-9]* failures?|error: Exited with|Fatal error|Test Case .* failed' "$log" >/dev/null; then
    echo "test-unit guard: failures in the console log:"; grep -aE '^✘ |✘ (Test|Suite)|Test run with .* failed|: error: -\[|Executed .* with [1-9][0-9]* failures?|error: Exited with|Fatal error|Test Case .* failed' "$log" | head -20
    bad=1
  fi
  local started ended
  started=$(grep -ac '◇ Test run started\.' "$log")
  ended=$(grep -acE '(✔|✘) Test run with [0-9]+ tests?' "$log")
  if [ "$started" -ne "$ended" ]; then
    echo "test-unit guard: $started Swift Testing run(s) started but $ended printed a summary (a test process ended early)"
    bad=1
  fi
  for x in "$@"; do
    [ -f "$x" ] || continue
    if grep -qE '<testsuite[^>]* (failures|errors)="[1-9]' "$x" || grep -q '<failure' "$x"; then
      echo "test-unit guard: failures in $x"; bad=1
    fi
  done
  return $bad
}

# run <name> <swift test args…>: one invocation, console teed to the log; returns the exit status.
run() {
  local name=$1; shift
  rm -f "$OUT/$name".xml "$OUT/$name"-swift-testing.xml
  set -o pipefail
  swift test "$@" --xunit-output "$OUT/$name.xml" 2>&1 | tee "$OUT/$name.log"
  local rc=$?
  set +o pipefail
  return $rc
}

guarded() {  # <name> <swift test args…>
  local name=$1
  run "$@"; local rc=$?
  check "$OUT/$name.log" "$OUT/$name.xml" "$OUT/$name-swift-testing.xml"; local g=$?
  if [ $rc -ne 0 ] || [ $g -ne 0 ]; then echo "test-unit: $name FAILED (swift test exit $rc, guard $g)"; return 1; fi
  echo "test-unit: $name passed"
}

cd "$ROOT"
COMMON=(--disable-keychain --force-resolved-versions)
if [ "${1:-}" = "--selftest" ]; then
  ok=1
  for mode in fail exit; do
    ANTICHAT_TEST_GUARD_SELFTEST=$mode run "selftest-$mode" "${COMMON[@]}" --filter TestUnitGuardSelfTests >/dev/null
    rc=$?
    if check "$OUT/selftest-$mode.log" "$OUT/selftest-$mode.xml" "$OUT/selftest-$mode-swift-testing.xml" >/dev/null; then
      echo "selftest $mode: NOT caught (swift test exit $rc)"; ok=0
    else
      echo "selftest $mode: caught (swift test exit $rc)"
    fi
  done
  # And a clean filtered run must pass the guard.
  run selftest-clean "${COMMON[@]}" --filter TestUnitGuardSelfTests >/dev/null
  if [ $? -eq 0 ] && check "$OUT/selftest-clean.log" "$OUT/selftest-clean.xml" >/dev/null; then echo "selftest clean: passes"; else echo "selftest clean: FAILED"; ok=0; fi
  # And the leftover check must see a tagged server-named process of this token only (a re-signed copy of sleep:
  # `ps -E` shows no environment for platform binaries).
  d="$OUT/leftover-selftest"; mkdir -p "$d"; cp /bin/sleep "$d/sd-server"; codesign -f -s - "$d/sd-server" 2>/dev/null
  tok=selftest-$(uuidgen)
  ANTICHAT_TEST_RUN_TOKEN=$tok "$d/sd-server" 30 & lp=$!
  sleep 0.5
  if tools/ci/test-leftovers.sh "$tok" | grep -q "^$lp " && [ -z "$(tools/ci/test-leftovers.sh "other-$tok")" ]; then
    echo "selftest leftover: caught"
  else
    echo "selftest leftover: NOT caught"; ok=0
  fi
  kill $lp 2>/dev/null; wait $lp 2>/dev/null
  [ -z "$(tools/ci/test-leftovers.sh "$tok")" ] || { echo "selftest leftover: still listed after kill"; ok=0; }
  [ $ok = 1 ] && echo "test-unit guard selftest: pass" || { echo "test-unit guard selftest: FAIL"; exit 1; }
  exit 0
fi

FILTER=${1:-}
status=0
export ANTICHAT_TEST_RUN_TOKEN=$(uuidgen)
CRASH_STAMP="$OUT/python-crash-stamp"
tools/ci/python-crash-reports.sh --touch "$CRASH_STAMP"
if [ -n "$FILTER" ]; then
  guarded main --parallel "${COMMON[@]}" --filter "$FILTER" || status=1
  if ! grep -qaE '(Executed [1-9][0-9]* test|Test run with [1-9][0-9]* test)' "$OUT/main.log"; then
    echo "test-unit: 0 tests ran for FILTER=$FILTER"; status=1
  fi
else
  guarded main --parallel "${COMMON[@]}" || status=1
  guarded childsafety --package-path Packages/ChildSafetyCheck "${COMMON[@]}" || status=1
fi
# No server or helper child started by THIS run may survive it: range-server.py (the download tests' fixture server;
# it stops on deinit, at test-process exit, and by itself when orphaned), llama-server / sd-server / sd-cli and their
# orphan watchdogs (fix/orphan-servers: every spawn is guarded, and tests stop what they start on every path).
# Scoped by the per-run token (other worktrees' concurrent runs have live servers of their own; older orphans carry
# none). Give a watchdog its SIGTERM → 3 s → SIGKILL, then fail.
leftover() {
  { tools/ci/range-server-leftovers.sh "$ANTICHAT_TEST_RUN_TOKEN" | sed 's/$/ range-server.py/'
    tools/ci/test-leftovers.sh "$ANTICHAT_TEST_RUN_TOKEN"; } | sort -u
}
for _ in $(seq 1 16); do [ -z "$(leftover)" ] && break; sleep 0.5; done
if [ -n "$(leftover)" ]; then
  echo "test-unit: processes started by this run are still running after the tests:"; leftover | sed 's/^/  /'
  status=1
fi
# Python crash reports (the "Python quit unexpectedly" popup) that appeared during the run. Fixture servers exit cleanly
# on SIGTERM, and a test that needs a dying interpreter must use SIGKILL (no report), never SIGSEGV/SIGABRT/SIGBUS.
# Other worktrees' concurrent runs write to the same directory, so this lists them as a warning; the run-scoped check is
# RangeServerLifetimeTests.stoppedServerLeavesNoCrashReport (children of the test process only). ANTICHAT_STRICT_CRASH_REPORTS=1 fails on any.
sleep 1
crashes=$(tools/ci/python-crash-reports.sh "$CRASH_STAMP")
if [ -n "$crashes" ]; then
  echo "test-unit: WARNING Python crash reports appeared during the run (possibly another worktree's run):"; echo "$crashes" | sed 's/^/  /'
  [ "${ANTICHAT_STRICT_CRASH_REPORTS:-0}" = 1 ] && status=1
fi
exit $status
