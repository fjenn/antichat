#!/usr/bin/env bash
# M2.T02 step 6 (contract 3, P-platform-08): no background URLSession anywhere in our code (a background session
# runs in nsurlsessiond, outside the gate and Offline only). Vendored donors and tests included; exit 1 on a hit.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
hits=$(git ls-files -- 'Packages/*.swift' 'App/*.swift' 'tools/*.swift' 'Vendor/*.swift' \
  | xargs grep -nE 'backgroundSessionConfiguration|URLSessionConfiguration\.background\(' 2>/dev/null || true)
if [[ -n $hits ]]; then echo "$hits"; echo "background URLSession is forbidden (NetworkGate contract)"; exit 1; fi
echo "ok: no background URLSession"
