#!/bin/bash
# range-server-leftovers.sh <run-token>: pids of the tools/fixtures/range-server.py processes started by ONE test run.
# tools/ci/test-unit.sh exports ANTICHAT_TEST_RUN_TOKEN; RangeServer (Platform test support) passes it to the server as
# `--run-token <token>`, so this sees only the run's own servers: other worktrees' concurrent runs (their own tokens)
# and orphans from before (no token) are ignored. Prints nothing when none is alive.
set -u
token=${1:?usage: range-server-leftovers.sh <run-token>}
case $token in *[!A-Za-z0-9-]*) echo "range-server-leftovers: bad token" >&2; exit 2;; esac
pgrep -f -- "range-server\.py .*--run-token $token( |\$)" || true
