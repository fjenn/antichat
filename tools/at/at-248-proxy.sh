#!/bin/bash
# M7.T01 AT-248 c2 (R-248 AC2) + M7.T02 AT-249 c1 (R-249 AC1), proxy leg: keyless search from the app process through proxy-logger.py (host:port per
# connection, no TLS interception). Starts the proxy, runs the hosted SearchProxyPathTests with
# ANTICHAT_SEARCH_PROXY, then checks build/at/AT-248/proxy.log: every host ⊆ the enabled engine hosts, zero
# AntiChat-operated hosts (*.vercel.app, antichat.*, the relay), no Google. Writes hosts.txt and c2-proxy.json.
# Usage: tools/at/at-248-proxy.sh [PORT]   (network: Q-007)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${1:-8898}"
OUT="$ROOT/build/at/AT-248"
mkdir -p "$OUT"; rm -f "$OUT/proxy.log"
python3 -I "$ROOT/tools/offline/proxy-logger.py" --port "$PORT" --log "$OUT/proxy.log" > "$OUT/proxy.out" 2>&1 & proxy=$!
trap 'kill $proxy 2>/dev/null' EXIT
sleep 1
TEST_RUNNER_ANTICHAT_SEARCH_PROXY="127.0.0.1:$PORT" make -C "$ROOT" test-integration-stub FILTER=SearchProxyPathTests > "$OUT/c2-proxy-xcodebuild.log" 2>&1
rc=$?
grep -a "SearchProxyPathTests" "$OUT/c2-proxy-xcodebuild.log" | grep -a "Test Case" | tail -2
python3 -I - "$OUT" "$rc" <<'PY'
import json, re, sys, time
out, rc = sys.argv[1], int(sys.argv[2])
allowed = {"html.duckduckgo.com", "search.brave.com", "www.mojeek.com", "www.startpage.com", "en.wikipedia.org"}
# M7.T02 AT-249 c1: + the hosts of the pages testFetchHostsOnly fetched (printed by the test), nothing else.
pages = set()
for line in open(f"{out}/c2-proxy-xcodebuild.log", encoding="utf-8", errors="replace"):
    if "AT-249-ALLOWED-HOSTS: " in line:
        pages |= set(line.split("AT-249-ALLOWED-HOSTS: ", 1)[1].strip().split(",")) - allowed
allowed |= pages
hosts = set()
try:
    for line in open(f"{out}/proxy.log", encoding="utf-8", errors="replace"):
        m = re.search(r"CONNECT ([^:\s]+):\d+", line) or re.search(r"\b[A-Z]+ https?://([^/:\s]+)", line)
        if m: hosts.add(m.group(1))
except FileNotFoundError:
    pass
# Loopback = the Debug catalog host the app fetches at launch (site-dev, :4321), not a search destination.
local = sorted(h for h in hosts if h in ("localhost", "127.0.0.1", "::1"))
hosts -= set(local)
antichat = sorted(h for h in hosts if h.endswith("vercel.app") or "antichat" in h)
google = sorted(h for h in hosts if "google" in h)
outside = sorted(hosts - allowed)
ok = rc == 0 and bool(hosts) and not outside and not antichat and not google
open(f"{out}/hosts.txt", "w").write("".join(h + "\n" for h in sorted(hosts)))
res = {"date": time.strftime("%Y-%m-%d"), "xcodebuild_rc": rc, "hosts": sorted(hosts), "allowed": sorted(allowed),
       "outside_allowed": outside, "loopback_excluded": local, "fetched_page_hosts": sorted(pages), "antichat_hosts": antichat, "google_hosts": google, "pass": ok,
       "a_m7_01": "proposed (SearXNG name and the 40 MB kit not met; native engines in the app process)"}
json.dump(res, open(f"{out}/c2-proxy.json", "w"), indent=1, sort_keys=True)
print(json.dumps(res, sort_keys=True))
sys.exit(0 if ok else 1)
PY
