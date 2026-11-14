#!/usr/bin/env bash
# AT-M0-08: ChildSafetyCheck latency/accuracy on lawful proxies (docs/prd/M0.md M0.T08; S-8).
#   1. swift test (decision rule truth table on stub scores + every fail-closed case; D-017)
#   2. hf-fetch --set csc (pinned, ungated, sha256-verified detectors)
#   3. csc-bench latency on 20 SFW CC0 photos x 20 runs (NFR-F7)
#   4. if P-PRIV (~/AntiChatPrivateFixtures/csc): csc-bench nudity | age | overblock (NFR-F1, F2, F6)
# Writes build/at/AT-M0-08/{<date>.log,result.json,*.json} with AGGREGATES ONLY (no private file names).
# Exit 0 for pass and pass-partial (missing private legs are carried to M4, M0.md step 7).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-08"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
FIXTURES="${FIXTURES:-$ROOT/fixtures}"
PRIV="${CSC_PRIVATE:-$HOME/AntiChatPrivateFixtures/csc}"
PKG="$ROOT/Packages/ChildSafetyCheck"
EP="${EP:-coreml}"
LOCK="/tmp/antichat-gpu.lock"   # one GPU-heavy job at a time (test-strategy §1)
gpu() { if command -v lockf >/dev/null; then lockf "$LOCK" "$@"; else "$@"; fi; }

echo "== AT-M0-08 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $(git rev-parse --short HEAD 2>/dev/null || echo none)"
echo "== step 1: unit tests (stub detectors only)"
set +e
swift test --package-path "$PKG" --disable-keychain 2>&1 | tee "$OUT/unit-tests.txt" | grep -E "✘|passed after|failed after|error:"
UNIT_RC=${PIPESTATUS[0]}
set -e
echo "unit tests exit $UNIT_RC"

echo "== step 2: detectors (hf-fetch --set csc)"
python3 -I tools/dev/hf-fetch.py --set csc

# Recorded M0 thresholds (S-8): m_face 8 meets F2 on both age sets; Marqo second signal off (T_n2 > 1)
# until M4 tunes it with adult positives (with it on at 0.50 the SFW leg is 1.07% > 1%).
TN="${TN:-0.35}"; TN2="${TN2:-1.01}"; MFACE="${MFACE:-8}"; MBODY="${MBODY:-12}"
TH=(--tn "$TN" --tn2 "$TN2" --mface "$MFACE" --mbody "$MBODY")

echo "== step 3: latency (NFR-F7), ep=$EP (Marqo still runs: worst-case cost)"
swift build -c release --package-path "$PKG" --disable-keychain 2>&1 | tail -1
BENCH="$(swift build -c release --package-path "$PKG" --disable-keychain --show-bin-path)/csc-bench"
gpu "$BENCH" latency --images "$FIXTURES/images/photos-cc0" --runs 20 --limit 20 --ep "$EP" "${TH[@]}" --out "$OUT/latency.json" >/dev/null
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d[k] for k in ("full_path_ms","as_used_sfw_ms","model_load_s","peak_footprint_mb","footprint_after_mb","n")})' "$OUT/latency.json"

if [ -d "$PRIV" ]; then
  echo "== step 4: P-PRIV present: accuracy legs (aggregates only)"
  rm -f "$OUT"/nudity.json "$OUT"/overblock.json "$OUT"/age-*.json
  if [ -f "$PRIV/nudity/labels.csv" ]; then
    gpu "$BENCH" nudity --set "$PRIV/nudity" --labels labels.csv --ep "$EP" "${TH[@]}" --out "$OUT/nudity.json" >/dev/null
    gpu "$BENCH" overblock --set "$PRIV/nudity" --labels labels.csv --ep "$EP" "${TH[@]}" --out "$OUT/overblock.json" >/dev/null
  fi
  for d in "$PRIV"/age/*/; do
    [ -f "$d/ages.csv" ] || continue
    name="$(basename "$d")"
    gpu "$BENCH" age --set "$d" --labels ages.csv --ep "$EP" "${TH[@]}" --out "$OUT/age-$name.json" >/dev/null
  done
else
  echo "== step 4: P-PRIV absent ($PRIV): F1/F2/F6 [PENDING-PRIVATE]"
fi

echo "== evaluate"
python3 -I - "$OUT" "$UNIT_RC" "$(git rev-parse HEAD 2>/dev/null || echo none)" "$ROOT/build/at/AT-M0-00/host.json" <<'PY'
import glob, json, os, sys
out, unit_rc, sha, hostf = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def load(name):
    p = os.path.join(out, name)
    return json.load(open(p)) if os.path.exists(p) else None
checks, pending = [], []
def add(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})
txt = open(os.path.join(out, "unit-tests.txt")).read()
add("unit tests (truth table + fail-closed, stub scores only)", "exit %d" % unit_rc, "exit 0, 0 failures",
    unit_rc == 0 and "✘" not in txt)
lat = load("latency.json")
add("NFR-F7 per-image p95 ms (full path: nudity+Marqo+Vision+MiVOLO per face, 20 img x 20 runs)",
    lat["full_path_ms"]["p95"], "<= 300", lat["full_path_ms"]["p95"] <= 300 and lat["n"] >= 400)
# K-019 RAM hypothesis (<= 0.5 GB) is evidence for the risk register, not an AT-M0-08 bar: reported, not judged.
info = {"k019_footprint_after_mb": lat["footprint_after_mb"], "k019_peak_footprint_mb": lat["peak_footprint_mb"],
        "k019_hypothesis_mb": 512, "model_load_s": lat["model_load_s"], "as_used_sfw_ms": lat["as_used_sfw_ms"]}
nud = load("nudity.json")
if nud and nud["n_nsfw_adult"] > 0:
    add("NFR-F1 nudity recall at precision >= 90%", nud["chosen_T_n"], "a T_n with recall >= 0.97", nud["chosen_T_n"] is not None)
else:
    pending.append("NFR-F1 (no adult NSFW proxy rows)")
ob = load("overblock.json")
if ob and ob["sfw"]["n"] > 0:
    add("NFR-F6 SFW withheld rate (full rule)", ob["sfw"]["withheld_rate"], "<= 0.01", ob["sfw"]["withheld_rate"] <= 0.01)
else:
    pending.append("NFR-F6 SFW leg")
if ob and ob["nsfw_adult"]["n"] > 0:
    add("NFR-F6 adult NSFW withheld rate (full rule)", ob["nsfw_adult"]["withheld_rate"], "<= 0.03", ob["nsfw_adult"]["withheld_rate"] <= 0.03)
else:
    pending.append("NFR-F6 adult NSFW leg (no adult NSFW proxy rows)")
ages = sorted(glob.glob(os.path.join(out, "age-*.json")))
for p in ages:
    a = json.load(open(p))
    s = a["at_m_face"]
    name = os.path.basename(p)[4:-5]
    add(f"NFR-F2 [{name}] recall <=15 at 18+m_face", s["recall_le15"], ">= 0.99", (s["recall_le15"] or 0) >= 0.99)
    add(f"NFR-F2 [{name}] recall 16-17 at 18+m_face", s["recall_16_17"], ">= 0.95", (s["recall_16_17"] or 0) >= 0.95)
    add(f"NFR-F2 [{name}] false flags >=30 at 18+m_face", s["false_flag_ge30"], "<= 0.05",
        s["false_flag_ge30"] is not None and s["false_flag_ge30"] <= 0.05)
if not ages:
    pending.append("NFR-F2 (no age proxy sets)")
else:
    pending.append("NFR-F2 illustrated faces (no illustrated set with ground-truth ages yet)")
ok = all(c["pass"] for c in checks)
status = ("pass-partial" if pending else "pass") if ok else "fail"
host = json.load(open(hostf)) if os.path.exists(hostf) else {}
res = {"at": "AT-M0-08", "pass": ok, "status": status, "checks": checks, "pending_private": pending, "info": info,
       "thresholds": lat["thresholds"], "commit": sha, "host": host or lat["host"]}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2, ensure_ascii=False)
for c in checks:
    print(("PASS " if c["pass"] else "FAIL ") + f'{c["name"]}: {c["value"]} (bar {c["bar"]})')
for p in pending:
    print("PENDING " + p)
print("INFO", json.dumps(info))
print("AT-M0-08:", status)
sys.exit(0 if ok else 1)
PY
