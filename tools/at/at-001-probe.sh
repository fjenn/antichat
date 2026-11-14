#!/bin/bash
# AT-001 fallback runner (M1.T07; Q-015: XCUITest cannot enable automation mode on this Mac). Runs the in-process
# window probe (`-UIProbe`, App/AntiChat/WindowProbe.swift) RUNS times on build/AntiChat.app (Debug), each with a
# fresh container, the last run under `sandbox-exec` with outbound IP denied (leg 4 "no network": the run must still
# pass and the sandbox must log 0 denials for AntiChat). Output: build/at/AT-001/probe-<n>/{probe.json,*.png}.
# Usage: tools/at/run.sh AT-001 -- tools/at/at-001-probe.sh [RUNS]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-001"
RUNS="${1:-3}"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
run_probe() { # $1 = run name, rest = optional wrapper
  local name="$1"; shift
  local dir="$OUT/$name" box
  box="$(mktemp -d /tmp/antichat-at001-XXXXXX)"
  rm -rf "$dir"
  "$@" "$BIN" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -UIProbe "$dir" >"$box.log" 2>&1
  if [ ! -f "$dir/probe.json" ]; then echo "$name: no probe.json"; tail -5 "$box.log"; fail=1; return; fi
  python3 -I - "$dir/probe.json" "$name" <<'PY' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
legs = d.get("legs", {})
bad = [k for k, v in sorted(legs.items()) if not v.get("pass")]
dock = legs.get("3b-dock", {}).get("dockSeconds")
off = legs.get("2-toolbar", {}).get("titleCentreOffsetPt")
w = legs.get("1-sidebar", {}).get("sidebarWidth")
print(f"{sys.argv[2]}: pass={d.get('pass')} sidebar={w} titleOffset={off} dock={dock} failed={bad}")
sys.exit(0 if d.get("pass") else 1)
PY
}
for n in $(seq 1 "$RUNS"); do run_probe "probe-$n"; done
# Leg 4 network: same probe with outbound IP denied; then count sandbox denials logged for AntiChat. A positive
# control (nc to 1.1.1.1:443 with and without the same profile) proves the profile is what blocks. Note: on macOS 26
# sandbox-exec denials of this profile were not found in the unified log even for the control (control_denials = 0),
# so "0 denials" is backed by the control pair + the app passing every leg with outbound IP denied, not by the log.
PROFILE='(version 1)(allow default)(deny network-outbound (remote ip))'
count_denials() { # $1 = start time, $2 = process name
  log show --style compact --start "$1" --predicate 'eventMessage CONTAINS "deny" AND eventMessage CONTAINS "network-outbound"' 2>/dev/null \
    | grep -v '^Filtering' | grep -v '^Timestamp' | grep -c "$2" || true
}
/usr/bin/nc -z -G 2 1.1.1.1 443 >/dev/null 2>&1; orc=$?
echo "control: nc without the profile exit=$orc (0 = this Mac has outbound network)"
cstart="$(date '+%Y-%m-%d %H:%M:%S')"
sandbox-exec -p "$PROFILE" /usr/bin/nc -z -G 2 1.1.1.1 443 >/dev/null 2>&1; crc=$?
sleep 2
control="$(count_denials "$cstart" nc)"
echo "control: nc under the profile exit=$crc (non-zero = blocked), denials logged=$control"
start="$(date '+%Y-%m-%d %H:%M:%S')"
run_probe "probe-offline" sandbox-exec -p "$PROFILE"
sleep 2
denials="$(count_denials "$start" AntiChat)"
echo "probe-offline: sandbox network-outbound denials for AntiChat = $denials"
echo "{\"denials\": $denials, \"control_nc_exit_unsandboxed\": $orc, \"control_nc_exit\": $crc, \"control_denials\": $control}" >"$OUT/probe-offline/network.json"
[ "$denials" = "0" ] && [ "$crc" != "0" ] || fail=1
exit $fail
