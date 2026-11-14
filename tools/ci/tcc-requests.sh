#!/usr/bin/env bash
# M8.T08 (AT-091 AC3; reused by M8.T14 AT-109): count the TCC requests one app made since a time.
#   tools/ci/tcc-requests.sh <bundle-id> <since "YYYY-MM-DD HH:MM:SS"> [service, default kTCCServiceLocation]
# Prints `<service> requests=<n>` and the matching log lines on stderr. Reads the unified log only (no admin).
# Location is not a TCC service in tccd's database on every macOS release; CoreLocation logs its own
# authorization requests under `com.apple.locationd`, so both subsystems are counted for kTCCServiceLocation.
set -euo pipefail
bundle="${1:?bundle id}"; since="${2:?since}"; service="${3:-kTCCServiceLocation}"
predicate="subsystem == \"com.apple.TCC\" AND eventMessage CONTAINS \"$bundle\" AND eventMessage CONTAINS \"$service\""
if [[ "$service" == kTCCServiceLocation ]]; then
  predicate="($predicate) OR (subsystem == \"com.apple.locationd\" AND eventMessage CONTAINS \"$bundle\" AND eventMessage CONTAINS[c] \"requestWhenInUse\")"
fi
lines="$(log show --style compact --predicate "$predicate" --start "$since" 2>/dev/null | grep -v '^Timestamp' | grep -v '^Filtering' || true)"
n=0; [[ -n "$lines" ]] && n="$(printf '%s\n' "$lines" | grep -c . || true)"
[[ -n "$lines" ]] && printf '%s\n' "$lines" >&2
echo "$service requests=$n"
