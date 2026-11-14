#!/bin/bash
# M2.T25 (AT-209 AC2 / R-297 AC2 destinations leg; AT-NFR-M5 throttled leg). Q-015: no XCUITest here, so the
# AllowedDestinationsTests form runs as this in-process path on build/AntiChat.app (Debug):
#   1. proxy-logger.py on 127.0.0.1:8899 (optionally `--rate RATE` Mbit/s, the non-sudo NFR-M5 throttle) and the
#      Debug catalog host (`site/public` on :4321, as `make site-dev` falls back to);
#   2. a fresh dev container, `-OnboardingProbe` (catalog fetch, real anonymous HF downloads of the starter + tier
#      model, first answer, hand-off) with `-TestProxy` so every gated session goes through the proxy;
#   3. the same container relaunched with `-SkipOnboarding YES -TestProxy` and left idle for IDLE_MIN minutes;
#   4. checks: every proxy destination ⊆ {catalog host, huggingface.co + its CDN hosts} and every proxied host has a
#      `network_activity` row (R-297 AC2). Legs not built yet (debug_fetch, update check stub) are reported pending.
# Usage: tools/at/run.sh AT-209 -- lockf /tmp/antichat-gpu.lock tools/at/at-209-destinations.sh
# Env: RATE (Mbit/s, default 0 = uncapped), IDLE_MIN (default 10), TIER (FakeHardware, default T1), ONB_PROBE_EVIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
OUT="$ROOT/build/at/AT-209/destinations"
rm -rf "$OUT"; mkdir -p "$OUT/probe"
BOX="$(mktemp -d /tmp/antichat-dest.XXXXXX)"
RATE="${RATE:-0}"; IDLE_MIN="${IDLE_MIN:-10}"; TIER="${TIER:-T1}"
python3 -I "$ROOT/tools/offline/proxy-logger.py" --log "$OUT/proxy.log" --rate "$RATE" > "$OUT/proxy.out" 2>&1 & proxy=$!
python3 -I -m http.server 4321 -b 127.0.0.1 -d "$ROOT/site/public" > "$OUT/site.log" 2>&1 & site=$!
trap 'kill $proxy $site 2>/dev/null' EXIT
sleep 1
common=(-ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$BOX" -TestProxy 127.0.0.1:8899
        -CatalogURL http://127.0.0.1:4321/catalog/v2/catalog.json -FakeHardware "$TIER")
echo "leg 1: onboarding probe (rate ${RATE:-0} Mbit/s, tier $TIER) $(date +%T)"
"$BIN" "${common[@]}" -ResetOnboarding YES -OnboardingProbe "$OUT/probe" > "$OUT/app-onboarding.log" 2>&1 &
app=$!
( sleep "${PROBE_TIMEOUT:-3600}"; kill "$app" 2>/dev/null ) & guard=$!
wait "$app"; kill "$guard" 2>/dev/null
echo "leg 2: idle ${IDLE_MIN} min $(date +%T)"
"$BIN" "${common[@]}" -SkipOnboarding YES > "$OUT/app-idle.log" 2>&1 & app=$!
sleep $((IDLE_MIN * 60)); kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
echo "done $(date +%T)"
python3 -I - "$OUT" "$BOX" "$RATE" <<'PY'
import glob, json, os, re, sqlite3, sys
out, box, rate = sys.argv[1], sys.argv[2], float(sys.argv[3])
hosts = {}
for line in open(os.path.join(out, "proxy.log"), encoding="utf-8", errors="replace") if os.path.exists(os.path.join(out, "proxy.log")) else []:
    m = re.search(r"CONNECT ([^:\s]+):\d+", line) or re.search(r"\b[A-Z]+ https?://([^/:\s]+)", line)
    if m:
        hosts[m.group(1)] = hosts.get(m.group(1), 0) + 1
allowed = re.compile(r"^(127\.0\.0\.1|localhost|huggingface\.co|([a-z0-9-]+\.)*(hf\.co|huggingface\.co|xethub\.hf\.co))$")
outside = sorted(h for h in hosts if not allowed.match(h))
dbs = [p for p in glob.glob(os.path.join(box, "**", "*.sqlite"), recursive=True)] + \
      [p for p in glob.glob(os.path.join(box, "**", "*.db"), recursive=True)]
rows = {}
for p in dbs:
    try:
        c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
        for h, cat, n in c.execute("SELECT host, category, count(*) FROM network_activity GROUP BY host, category"):
            rows.setdefault(h, {})[cat] = n
    except sqlite3.Error:
        pass
unmatched = sorted(h for h in hosts if h not in rows and h not in ("127.0.0.1", "localhost"))
probe = json.load(open(os.path.join(out, "probe", "probe.json"))) if os.path.exists(os.path.join(out, "probe", "probe.json")) else {}
m5 = probe.get("nfr.M5.continueToFirstToken.s")
res = {"proxy_hosts": hosts, "outside_allowed": outside, "activity_rows": rows, "proxied_without_row": unmatched,
       "databases": dbs, "rate_mbit": rate, "nfr.M5.continueToFirstToken.s": m5,
       "pending": ["debug_fetch leg (tool not built yet)", "update-check stub leg (Sparkle feed stub not wired in Debug)"],
       "pass": bool(hosts) and not outside and not unmatched}
json.dump(res, open(os.path.join(out, "destinations.json"), "w"), indent=2, sort_keys=True)
print(json.dumps({k: res[k] for k in ("proxy_hosts", "outside_allowed", "proxied_without_row", "nfr.M5.continueToFirstToken.s", "pass")}))
sys.exit(0 if res["pass"] else 1)
PY
