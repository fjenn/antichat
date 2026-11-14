#!/bin/bash
# AT-FA-04 offline chat (test-strategy §7.2 "Wi-Fi off / no route"): the VM's network service is switched off inside
# the guest (Tart's guest agent talks over vsock, so the VM stays controllable), then one chat turn on the installed
# models: the answer streams, the sidebar indicator is `net.offline`, and the app recorded no network attempt
# (network_activity rows during the leg; every gated connection writes one, allowed or blocked).
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-04)"; p="$HOME/fa/offline"; rm -rf "$p"
svc="$(networksetup -listallnetworkservices | sed 1d | sed 's/^\*//' | head -1)"
echo "network service: $svc"
restore() { sudo networksetup -setnetworkserviceenabled "$svc" on; }
trap restore EXIT
sudo networksetup -setnetworkserviceenabled "$svc" off
sleep 5
curl -s -m 5 -o /dev/null https://huggingface.co && online=1 || online=0
echo "$online" > "$o/reachable-after-off.txt"
since=$(sql 'SELECT coalesce(max(id), 0) FROM network_activity')
probe "$p" chat 1800
cp -R "$p/." "$o/"
restore; trap - EXIT
j="$o/probe.json"
check "the VM really is offline (huggingface.co unreachable)" "[ $online = 0 ]"
check "the answer streamed and finished on the installed model ($(json "$j" 'j["slot"]'))" "[ \"\$(json '$j' 'j[\"pass\"]')\" = True ]"
check "the app saw the path as offline (PathStatus none)" "[ \"\$(json '$j' 'j[\"pathOffline\"]')\" = True ]"
check "sidebar indicator mode is net.offline (NetworkIndicator.current: Offline only off, path offline)" "[ \"\$(json '$j' 'j[\"indicator\"]')\" = net.offline ]"
[ "$(json "$j" 'j["indicatorShown"]')" = True ] || note "net.offline label seen on screen: its probe anchor was not laid out in the background window (indicator mode computed from the same sources; RC visual QA)"
sql "SELECT ts, category, host, outcome FROM network_activity WHERE id > $since" > "$o/network-activity.txt"
# Loopback is not the network (the Debug build's catalog host is localhost:4321, a dev server; Release's is remote).
grep -v -E '\|(localhost|127\.0\.0\.1|::1)\|' "$o/network-activity.txt" > "$o/network-activity-outbound.txt" || true
check "no outbound attempt from AntiChat while offline (non-loopback network_activity rows: $(wc -l < "$o/network-activity-outbound.txt" | tr -d ' '); all rows in network-activity.txt)" "[ ! -s '$o/network-activity-outbound.txt' ]"
fa_result "$o" AT-FA-04 "dev (Debug test build, clean VM, network service off)"
