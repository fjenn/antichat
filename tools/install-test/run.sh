#!/bin/bash
# make test-install CASE=<clean|move|upgrade|downgrade|model-rollback|remove-everything|uninstall|reinstall|all>[,<case>…]
#                   ENV=<tart|user|dev>   (M8.T11 step 5; test-strategy §8)
# tart: a fresh clone of the `antichat-clean-26.x` VM per case (tart-run.sh); user: a fresh macOS user
# (fresh-user-run.sh, needs the owner's one-time admin approval); dev: this Mac, a scratch ANTICHAT_ROOT + dev
# container (the fast pre-check; no login-item / Trash leg). Logs → build/at/AT-226/ and build/at/AT-NFR-D7/.
# This task implements remove-everything, uninstall, reinstall; clean/move/upgrade/downgrade/model-rollback are M10.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cases="${CASE:-all}" env="${ENV:-dev}"
[ "$cases" = all ] && cases="remove-everything,uninstall,reinstall"
date="$(date +%F)"
rc=0
for c in ${cases//,/ }; do
  case "$c" in
    remove-everything) at=AT-NFR-D7 ;;
    uninstall|reinstall) at=AT-226 ;;
    clean|move|upgrade|downgrade|model-rollback) echo "$c: built in M10 (harness only here)"; continue ;;
    *) echo "unknown CASE $c" >&2; exit 2 ;;
  esac
  out="$root/build/at/$at"; mkdir -p "$out"
  log="$out/$date-$c-$env.log"
  case "$env" in
    tart) "$here/tart-run.sh" "$c" >"$log" 2>&1 ;;
    user) "$here/fresh-user-run.sh" "$c" >"$log" 2>&1 ;;
    dev) "$here/dev-run.sh" "$c" >"$log" 2>&1 ;;
    *) echo "unknown ENV $env" >&2; exit 2 ;;
  esac
  r=$?
  case $r in
    0) echo "PASS $c ($env) → ${log#"$root"/}" ;;
    3) echo "NOT RUN $c ($env): $(tail -1 "$log") → ${log#"$root"/}"; rc=3 ;;
    *) echo "FAIL $c ($env) → ${log#"$root"/}"; tail -20 "$log"; rc=1 ;;
  esac
done
exit $rc
