#!/usr/bin/env bash
# M2.T03 step 6 (AT-209 AC1, test-strategy §7.1): run the Debug app under the deny-outbound sandbox with Offline
# only on, then count sandbox denials attributable to AntiChat / AntiChatEngine / llama-server and list their
# non-unix sockets (lsof). The UI journeys drive this instance in attach mode (TEST_RUNNER_ANTICHAT_ATTACH=1);
# while XCUITest cannot start (Q-015) the app runs SECONDS idle, or with the extra app arguments after `--`
# (e.g. an in-process probe). Exit 1 on any denial or IP socket.
#   tools/offline/run-offline.sh [SECONDS] [-- <extra app args>]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
secs=${1:-20}; [[ $# -gt 0 ]] && shift; [[ ${1:-} == -- ]] && shift
out="$root/build/at/AT-209"; mkdir -p "$out"
tmp=$(mktemp -d); trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
app="${APP:-$root/build/AntiChat.app}/Contents/MacOS/AntiChat"
start=$(date '+%Y-%m-%d %H:%M:%S')
sandbox-exec -f "$root/tools/offline/deny-outbound.sb" "$app" -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$tmp/c" \
  -DefaultsSuite "app.antichat.offline-test" "$@" > "$out/app.log" 2>&1 &
pid=$!
sleep "$secs"
pids=$(pgrep -f 'AntiChat.app/Contents|AntiChatEngine|llama-server' | tr '\n' ',' | sed 's/,$//')
lsof -nP -a -p "${pids:-$pid}" -i 2>/dev/null | tee "$out/lsof-ip.txt" >/dev/null || true
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
log show --start "$start" --predicate 'eventMessage CONTAINS "deny(1) network-outbound"' --style compact 2>/dev/null \
  | grep -E 'AntiChat|AntiChatEngine|llama-server' > "$out/sandbox-denies.log" || true
denies=$(wc -l < "$out/sandbox-denies.log" | tr -d ' ')
ipsocks=$(grep -vc '^COMMAND' "$out/lsof-ip.txt" || true)
echo "run-offline: ${secs}s under deny-outbound, Offline only on: sandbox denies=$denies, IP sockets=$ipsocks"
[[ $denies -eq 0 && ${ipsocks:-0} -eq 0 ]]
