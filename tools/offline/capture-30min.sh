#!/usr/bin/env bash
# M2.T03 (AT-NFR-PR1 §7.3): 30-minute capture with Offline only on: `nettop -P -L 0` per-PID bytes and, when sudo
# is available without a password, `tcpdump -i any`. Without sudo the nettop + lsof path is authoritative and the
# pcap leg is logged "not run: permission" (M2.md permission preconditions). MINUTES overrides the length.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$root/build/at/AT-NFR-PR1"; mkdir -p "$out"
mins=${MINUTES:-30}
if sudo -n true 2>/dev/null; then
  sudo -n tcpdump -i any -w "$out/capture.pcap" & tcpdump_pid=$!
else
  echo "tcpdump: not run: permission (sudo -n refused)" | tee "$out/pcap-status.txt"; tcpdump_pid=
fi
"$root/tools/offline/run-offline.sh" $((mins * 60)) "$@" & run_pid=$!
end=$((SECONDS + mins * 60))
: > "$out/nettop.csv"; : > "$out/pids.txt"
# M9.T05: count only the processes of the app under test (its bundle path: the app, its XPC helpers, llama-server in
# Contents/Helpers), so another AntiChat build on the Mac (a soak, an orphaned test app) is never attributed to it.
app_bundle="${APP:-$root/build/AntiChat.app}"
bundle="$(cd "$(dirname "$app_bundle")" && pwd)/$(basename "$app_bundle")"
while (( SECONDS < end )); do
  pgrep -f "$bundle/" >> "$out/pids.txt" 2>/dev/null || true
  nettop -P -L 1 -x -J bytes_in,bytes_out >> "$out/nettop.csv" 2>/dev/null || true
  sleep 30
done
wait "$run_pid"; rc=$?
[[ -n ${tcpdump_pid:-} ]] && sudo -n kill "$tcpdump_pid" 2>/dev/null || true
sum_bytes() {  # $1 = 1: PIDs of the app under test; 0: every other AntiChat/llama-server PID (reported, not counted)
  { grep -E 'AntiChat|llama-server' "$out/nettop.csv" || true; } | awk -F, -v pf="$out/pids.txt" -v mine="$1" '
    BEGIN { while ((getline p < pf) > 0) keep[p] = 1 }
    { n = split($1, a, "."); if (((a[n] in keep) ? 1 : 0) == mine) s += $2 + $3 } END { print s + 0 }'
}
bytes=$(sum_bytes 1); others=$(sum_bytes 0)
echo "capture: nettop bytes for the app-under-test PIDs ($(sort -u "$out/pids.txt" | wc -l | tr -d ' ') under $bundle) = $bytes (loopback/unix excluded by nettop -P); other AntiChat processes on the Mac: $others bytes (not counted)"
[[ $rc -eq 0 && $bytes -eq 0 ]]
