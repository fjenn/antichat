#!/bin/bash
# python-crash-reports.sh [--parent <pid>] <stamp-file>: Python crash reports macOS wrote after <stamp-file> was last touched
# (~/Library/Logs/DiagnosticReports/Python-*.ips = the "Python quit unexpectedly" popups). A fixture server that is
# stopped must exit cleanly (SIGTERM handled, SIGKILL last resort); SIGSEGV/SIGABRT/SIGBUS make the crash reporter write
# one. `--parent <pid>` keeps only reports of Python processes that were children of <pid> (other worktrees' concurrent
# test runs write reports to the same directory). Prints one path per line; nothing when there is none. `--touch <stamp-file>` creates/refreshes the stamp.
set -u
if [ "${1:-}" = "--touch" ]; then touch "${2:?usage: python-crash-reports.sh --touch <stamp-file>}"; exit 0; fi
parent=""
if [ "${1:-}" = "--parent" ]; then parent=${2:?--parent needs a pid}; shift 2; fi
case $parent in *[!0-9]*) echo "python-crash-reports: bad pid" >&2; exit 2;; esac
stamp=${1:?usage: python-crash-reports.sh [--parent <pid>] <stamp-file>}
dir="${ANTICHAT_DIAGNOSTIC_REPORTS:-$HOME/Library/Logs/DiagnosticReports}"
[ -f "$stamp" ] || { echo "python-crash-reports: no stamp $stamp" >&2; exit 2; }
find "$dir" -maxdepth 1 -name 'Python*.ips' -newer "$stamp" 2>/dev/null | sort | while read -r f; do
  [ -z "$parent" ] || grep -q "\"parentPid\" *: *$parent[,}]" "$f" 2>/dev/null || continue
  echo "$f"
done
exit 0
