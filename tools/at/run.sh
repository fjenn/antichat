#!/usr/bin/env bash
# AT runner (docs/prd/M1.md convention 2; M1.T02 step 2).
#   tools/at/run.sh <AT-ID> -- <command…>
# Tees stdout+stderr to build/at/<AT-ID>/<YYYY-MM-DD>.log (truncated per run, CR-P-09), writes
# build/at/<AT-ID>/result.json via tools/at/result.py and exits with the command's status.
# Pending forward legs (convention 9): the inner command (or the task) lists them one per line in
# build/at/<AT-ID>/pending.txt; any listed leg makes "pass": false.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
[[ $# -ge 1 ]] || { echo "usage: tools/at/run.sh <AT-ID> -- <command…>" >&2; exit 64; }
id=$1; shift
[[ ${1:-} == -- ]] && shift
[[ $# -ge 1 ]] || { echo "run.sh: no command given for $id" >&2; exit 64; }
[[ $id =~ ^[A-Za-z0-9._-]+$ ]] || { echo "run.sh: bad AT id '$id'" >&2; exit 64; }
mkdir -p "build/at/$id"
log="build/at/$id/$(date +%F).log"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
python3 -I tools/at/result.py "$id" "$*" "$rc" --started "$started" --log "$log" > "build/at/$id/result.json.tmp"
mv "build/at/$id/result.json.tmp" "build/at/$id/result.json"
exit "$rc"
