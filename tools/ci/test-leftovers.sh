#!/bin/bash
# test-leftovers.sh <run-token>: pids of the server / helper children started by ONE test run that are still alive
# (fix/orphan-servers). tools/ci/test-unit.sh exports ANTICHAT_TEST_RUN_TOKEN; every child a test spawns inherits it
# (llama-server, sd-server and the orphan watchdog take the environment as is; the range server also gets it as
# `--run-token`), so `ps -E` attributes them to this run only: other worktrees' concurrent runs carry their own token
# and orphans from before carry none. Covered: llama-server, sd-server, sd-cli, the watchdog (the bundled tool, the
# helper re-exec and the bash fallback all run as `antichat-llama-watchdog`) and tools/fixtures/range-server.py.
# A video child gets an allow-listed environment (no token) but is never alive without its watchdog.
# Prints "pid command" lines; nothing when none is alive.
set -u
token=${1:?usage: test-leftovers.sh <run-token>}
case $token in *[!A-Za-z0-9-]*) echo "test-leftovers: bad token" >&2; exit 2;; esac
me=$$
ps -E -ww -axo pid=,command= 2>/dev/null | awk -v tok="ANTICHAT_TEST_RUN_TOKEN=$token" -v me="$me" '
  $1 == me { next }
  {
    hit = 0
    for (i = 2; i <= NF; i++) if ($i == tok) { hit = 1; break }
    if (!hit) next
    if ($2 ~ /(^|\/)(llama-server|sd-server|sd-cli|llama-watchdog|antichat-llama-watchdog)$/ || $0 ~ /range-server\.py /) {
      line = $1 " " $2
      for (i = 3; i <= NF && i <= 8 && $i !~ /^[A-Za-z_][A-Za-z0-9_]*=/; i++) line = line " " $i  # argv, not env
      print substr(line, 1, 200)
    }
  }'
exit 0
