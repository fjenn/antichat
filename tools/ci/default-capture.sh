#!/usr/bin/env bash
# AT-NFR-PR1, M7 extension (M7.T15 step 7; test-strategy §7.4 "default-settings capture"; NFR-PR1, NFR-PR5).
# Fresh dev container + throwaway defaults suite (= a fresh user's settings: web search On, no search made), the Debug
# app idle for MINUTES. Sources, each recorded in the report:
#   ledger   the app's own `network_activity` rows (NetworkGate: every gated request, host + category)
#   nettop   `nettop -L 1 -x` per-connection rows of the AntiChat PIDs (remote IPs), sampled every 15 s — the check
#            that no byte left outside the gate: every remote IP must resolve from a host the ledger names
#   tcpdump  only when /dev/bpf0 is readable without sudo (never prompts for a password); else "not run: permission"
# Pass, phase 1 (idle): ledger hosts ⊆ {catalog host, Sparkle appcast host} and no search/relay/MCP category;
#   NFR-PR5: Sparkle system profiling off in the built Info.plist (SUEnableSystemProfiling = false) and the appcast
#   URL carries no query (Sparkle then sends no profile query string: version/OS/arch are in its User-Agent only).
# Phase 2: one search (the in-process `-SearchProbe` chip leg, real engines, `-ScriptedWebSearch NO`) in the same
#   container → search hosts appear, and only after it. No relay host unless Connections were used (they are not).
# Isolation: this Mac, a fresh container and suite, nettop filtered by our PIDs — "reduced isolation" (no Tart VM /
# fresh macOS user, M7.md failure-mode row; [ASSUMPTION]).
#   tools/ci/default-capture.sh [--minutes N] [--out DIR] [--no-search]
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mins=30; out="$root/build/at/AT-NFR-PR1"; search=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --minutes) mins=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --no-search) search=0; shift ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done
app="${APP:-$root/build/AntiChat.app}"
bin="$app/Contents/MacOS/AntiChat"
[[ -x $bin ]] || { echo "missing $bin (make build)"; exit 2; }
day=$(date +%Y-%m-%d)
mkdir -p "$out"
work=$(mktemp -d /tmp/antichat-defcap-XXXXXX)
box="$work/c"; suite="antichat-defcap-$(basename "$work")"
cleanup() { [[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null; [[ -n ${tdpid:-} ]] && kill "$tdpid" 2>/dev/null; defaults delete "$suite" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"; }
trap cleanup EXIT

sources="ledger,nettop"
if [[ -r /dev/bpf0 ]]; then
  tcpdump -i any -n -w "$out/$day.default.pcap" 'not net 127.0.0.0/8' >/dev/null 2>&1 & tdpid=$!
  sources="$sources,tcpdump"
else
  echo "tcpdump: not run: permission (/dev/bpf0 not readable without sudo; no password prompt by design)" > "$out/$day.pcap-status.txt"
fi

nettop_sample() {  # <file> <pid…>: per-connection rows of these PIDs (remote endpoint), loopback/unix dropped
  local f=$1; shift
  for p in "$@"; do
    nettop -L 1 -x -n -p "$p" 2>/dev/null | grep -E 'tcp|udp|quic' | grep -vE '127\.0\.0\.1|::1|\*\.\*' >> "$f" || true
  done
}
ourpids() { pgrep -f "$work" | tr '\n' ' '; }

# Phase 1: idle with default settings. Only the window may be needed to start; nothing is clicked.
start_ts=$(date +%s)
"$bin" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES \
  > "$out/$day.default-app.log" 2>&1 & pid=$!
: > "$out/$day.nettop-idle.txt"
end=$((SECONDS + mins * 60))
while (( SECONDS < end )); do
  kill -0 "$pid" 2>/dev/null || { echo "app exited early"; break; }
  # shellcheck disable=SC2046
  nettop_sample "$out/$day.nettop-idle.txt" $pid $(ourpids)
  sleep 15
done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=
idle_end_ts=$(date +%s)
db=$(find "$box" -name antichat.sqlite -print -quit 2>/dev/null)
[[ -n $db ]] || db=""
ledger_idle=""
[[ -n $db ]] && ledger_idle=$(sqlite3 -separator ' ' "$db" "SELECT category, host, outcome, COUNT(*) FROM network_activity GROUP BY 1,2,3" 2>/dev/null)
idle_max_id=0
[[ -n $db ]] && idle_max_id=$(sqlite3 "$db" "SELECT COALESCE(MAX(id), 0) FROM network_activity" 2>/dev/null || echo 0)

# Phase 2: one search.
ledger_search=""; search_rc="not run"
if [[ $search == 1 ]]; then
  pdir="$out/$day.search-probe"; rm -rf "$pdir"; mkdir -p "$pdir"; echo chip > "$pdir/mode"
  : > "$out/$day.nettop-search.txt"
  "$bin" -ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -DefaultsSuite "$suite" -SkipOnboarding YES \
    -ChatModel chat-9b-q4 -UseScriptedEngine "$root/tools/fixtures/scripts/web-search.jsonl" -ScriptedWebSearch NO \
    -SearchProbe "$pdir" > "$pdir/launch.log" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    # shellcheck disable=SC2046
    nettop_sample "$out/$day.nettop-search.txt" $pid $(ourpids); sleep 2
  done
  wait "$pid"; search_rc=$?; pid=
  [[ -n $db ]] && ledger_search=$(sqlite3 -separator ' ' "$db" \
    "SELECT category, host, outcome, COUNT(*) FROM network_activity WHERE id > $idle_max_id GROUP BY 1,2,3" 2>/dev/null)
fi
[[ -n ${tdpid:-} ]] && { kill "$tdpid" 2>/dev/null; tdpid=; }

plist="$app/Contents/Info.plist"
profiling=$(/usr/libexec/PlistBuddy -c "Print :SUEnableSystemProfiling" "$plist" 2>/dev/null || echo missing)
python3 -I - "$out/$day.default.json" "$mins" "$sources" "$profiling" "$root/Config/Endpoints.plist" "$search_rc" \
  "$out/$day.nettop-idle.txt" "$start_ts" <<PY
import json, plistlib, re, socket, sys, urllib.parse
dest, mins, sources, profiling, endpoints, search_rc, nettop_idle, start = sys.argv[1:9]
idle = [l.split() for l in """$ledger_idle""".splitlines() if l.strip()]
srch = [l.split() for l in """$ledger_search""".splitlines() if l.strip()]
ep = plistlib.load(open(endpoints, "rb"))
hosts = lambda *keys: {urllib.parse.urlsplit(ep[k]).hostname for k in keys if k in ep}
# the build's catalog URL (Debug: CatalogURLDev, the local dev site) + the Sparkle appcast hosts
allowed = hosts("CatalogURL", "CatalogURLDev", "AppcastURL", "AppcastDevURL")
appcast_query = any(urllib.parse.urlsplit(ep.get(k, "")).query for k in ("AppcastURL", "AppcastDevURL"))
idle_hosts = sorted({r[1] for r in idle})
idle_cats = sorted({r[0] for r in idle})
bad = [h for h in idle_hosts if h not in allowed]
online_cats = [c for c in idle_cats if c in ("search", "relay", "mcp", "connectors")]
# nettop cross-check: every remote IP of an AntiChat connection resolves from a host the ledger names
ips = set()
for line in open(nettop_idle, encoding="utf-8", errors="replace"):
    m = re.search(r"<->(\S+)", line)
    if m:  # IPv4 "a.b.c.d:port", IPv6 "addr.port"
        e = m.group(1)
        ips.add(e.rsplit(":", 1)[0] if e.count(":") == 1 else e.rsplit(".", 1)[0])
resolved = set()
for h in idle_hosts:
    try: resolved |= {a[4][0] for a in socket.getaddrinfo(h, 443)}
    except OSError: pass
stray = sorted(ip for ip in ips if ip not in resolved)
search_hosts = sorted({r[1] for r in srch if r[0] == "search"})
relay_any = any(r[0] == "relay" for r in idle + srch)
checks = {
    "idle_hosts_only_catalog_and_sparkle": not bad,
    "idle_no_search_relay_mcp_category": not online_cats,
    "nfr_pr5_system_profiling_off": profiling.strip() == "false",
    "nfr_pr5_appcast_url_has_no_query": not appcast_query,
    "nettop_ips_all_from_ledger_hosts": not stray,
    "search_hosts_only_after_search": (search_rc == "not run") or (bool(search_hosts) and not any(r[0] == "search" for r in idle)),
    "no_relay_host": not relay_any,
}
report = {"at": "AT-NFR-PR1 (M7 extension, test-strategy §7.4)", "minutes": float(mins), "sources": sources.split(","),
          "isolation": "reduced: this Mac, fresh dev container + defaults suite, nettop filtered by AntiChat PIDs [ASSUMPTION]",
          "allowed_hosts": sorted(allowed), "idle_ledger": idle, "idle_hosts": idle_hosts, "idle_remote_ips": sorted(ips),
          "stray_ips": stray, "search_probe_exit": search_rc, "search_ledger": srch, "search_hosts": search_hosts,
          "checks": checks, "pass": all(checks.values())}
json.dump(report, open(dest, "w"), indent=2, sort_keys=True)
print(json.dumps({"checks": checks, "idle_hosts": idle_hosts, "search_hosts": search_hosts}, indent=1))
sys.exit(0 if report["pass"] else 1)
PY
