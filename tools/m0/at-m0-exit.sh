#!/usr/bin/env bash
# AT-M0-EXIT (docs/prd/M0.md, M0.T15 "AT-M0 exit check"; PRD §7 M0 "Exit"):
#  1. build/at/AT-M0-00…13/result.json exist and pass (pass-partial / fallback needs an amendment ID in spikes.json)
#  2. registry/spikes.json has exactly S-0, S-1, S-1b, S-3…S-14
#  3. G-067 and G-068 are `closed` in registry/gaps.json
#  4. every NFR of PRD §4 row M0 is annotated "measured M0" in 02-target/nfr.md
#  5. docs/prd/M0-report.md is committed
#  6. python3 tools/trace-check.py --phase 11 shows no violation
#  7. AT-VQ-M0 result.json is `pass` (`pending` while the computer-use run has not happened → exit 2)
# Writes build/at/AT-M0-EXIT/{<date>.log,result.json}; exits 0 only on pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-EXIT"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SHA="$(git rev-parse HEAD)"
echo "== AT-M0-EXIT $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA"

set +e
TRACE="$(python3 -I tools/trace-check.py --phase 11 2>&1)"
TRACE_RC=$?
REPORT_TRACKED=0
git ls-files --error-unmatch docs/prd/M0-report.md >/dev/null 2>&1 && REPORT_TRACKED=1
python3 -I - "$OUT/result.json" "$SHA" "$TRACE_RC" "$REPORT_TRACKED" "$TRACE" <<'PY'
import json, os, re, sys
out, sha, trace_rc, tracked, trace = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
checks = []
def chk(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {value} (bar: {bar})")

spikes = json.load(open("docs/research/registry/spikes.json"))
by_gate = {s["gate"]: s for s in spikes}
for n in range(14):
    at = f"AT-M0-{n:02d}"
    p = f"build/at/{at}/result.json"
    if not os.path.isfile(p):
        chk(f"{at} result.json", "missing", "pass", False); continue
    r = json.load(open(p))
    st = str(r.get("status") or ("pass" if r.get("pass") else "fail"))
    sp = by_gate.get(at, {})
    needs_amendment = st.startswith("pass-partial") or bool(sp.get("fallback_adopted"))
    ok = r.get("pass") is True and (not needs_amendment or bool(sp.get("amendment")))
    chk(f"{at} result", st, "pass (pass-partial/fallback needs an amendment)", ok)

want = ["S-0", "S-1", "S-1b", "S-3", "S-4", "S-5", "S-6", "S-7", "S-8", "S-9", "S-10", "S-11", "S-12", "S-13", "S-14"]
ids = [s["id"] for s in spikes]
chk("spikes.json rows", ids, want, sorted(ids) == sorted(want) and len(ids) == len(set(ids)))

gaps = {g["id"]: g for g in json.load(open("docs/research/registry/gaps.json"))}
for g in ("G-067", "G-068"):
    chk(f"{g} closed", gaps[g]["status"], "closed", gaps[g]["status"] == "closed")

nfr = open("docs/research/02-target/nfr.md", encoding="utf-8").read()
miss = []
for n in "C1 C1b C2 C4 M1 M3 M5 V1 P1 P2 VID1 F1 F2 F6 F7 C7 R1".split():
    row = re.search(rf"^\| NFR-{n} \|.*$", nfr, re.M)
    if not row or "measured M0" not in row.group(0):
        miss.append(n)
chk("nfr.md 'measured M0' annotations (17)", miss or "all", "none missing", not miss)

chk("docs/prd/M0-report.md committed", tracked, True, tracked)
chk("trace-check --phase 11", trace.strip().splitlines()[-1] if trace.strip() else "", "OK", trace_rc == 0)

vq = "build/at/AT-VQ-M0/result.json"
vqs = json.load(open(vq)).get("status") if os.path.isfile(vq) else "missing"
chk("AT-VQ-M0", vqs, "pass", vqs == "pass")

others_ok = all(c["pass"] for c in checks if c["name"] != "AT-VQ-M0")
status = "pass" if others_ok and vqs == "pass" else ("pending" if others_ok and vqs == "pending" else "fail")
json.dump({"at": "AT-M0-EXIT", "pass": status == "pass", "status": status, "checks": checks, "commit": sha},
          open(out, "w"), indent=2)
print(f"== AT-M0-EXIT {status.upper()}")
sys.exit({"pass": 0, "pending": 2}.get(status, 1))
PY
rc=$?
set -e
exit $rc
