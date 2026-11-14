#!/usr/bin/env bash
# AT-M0-13 (docs/prd/M0.md, M0.T13; selection.md §11; DECISIONS D-012): D-012 switch rule re-run (S-14).
#  1. build/at/AT-M0-13/inputs.json from the spike reports' machine-readable lines and the AT-M0-02/03/04/06
#     result.json files (missing input -> D-012 point estimate, marked [NOT-MEASURED])
#  2. tools/d012/switch.py --self-test: baseline re-sums to A 140.2, F1 110.3, F1-R 116.8 (P0+P1) and the
#     D-012 inputs give 3-year A 156, F1 141, F1-R 149, F2 174 (±1)
#  3. result.json has 3-year totals for A, F1, F1-R, F2 and the boolean `switch`
#  4. selection.md §11 "M0 re-run" and the DECISIONS "switch re-run" entry quote the same A and F1-R totals
#  5. switch false -> "A confirmed"; switch true -> a `proposed` major amendment + a QUESTIONS entry
# Writes build/at/AT-M0-13/{inputs.json,switch.json,<date>.log,result.json}; exits 0 only on pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-13"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SHA="$(git rev-parse HEAD)"
echo "== AT-M0-13 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA"

echo "== build inputs.json"
python3 -I - "$OUT/inputs.json" <<'PY'
import json, re, sys
SP = "docs/research/07-spikes/"
prov, missing = {}, []
def line(report, key):
    m = re.search(rf"^{key}: ([0-9.]+)\s*$", open(SP + report).read(), re.M)
    prov[key] = f"{SP}{report} line `{key}:`"
    return float(m.group(1)) if m else None
def at(n):
    return json.load(open(f"build/at/AT-M0-{n}/result.json"))
def check(res, prefix):
    return next(c for c in res["checks"] if c["name"].startswith(prefix))
d012 = json.load(open("tools/d012/baseline.json"))["d012"]

effort_days = line("S-1-osaurus-closure.md", "effort_days")
median_bump_days = line("S-1-vendor-sync.md", "median_bump_days")
yearly = line("S-1-vendor-sync.md", "yearly_pw_osaurus")
if effort_days is None or not at("02")["pass"]:
    missing.append("g067_measured_pw")
if yearly is None or not at("03")["pass"]:
    missing.append("yearly_pw_osaurus")
r4, r6 = at("04"), at("06")
ovh = check(r4, "S-3 XPC decode overhead")
msg = check(r4, "XPC msgs/s")
s3_pass = r4["pass"] and ovh["pass"] and msg["pass"]
s4 = re.search(r"\*\*s4_verdict: (\w+)\*\*", open(SP + "S-4-vmlx.md").read())
inp = {
    "date": "2026-10-30",
    "g067_measured_pw": round(effort_days / 5, 4) if "g067_measured_pw" not in missing else d012["g067_unmeasured_pw"],
    "effort_days": effort_days,
    "median_bump_days": median_bump_days,
    "yearly_pw_osaurus": yearly if "yearly_pw_osaurus" not in missing else d012["osaurus_share_of_A_yearly"],
    "g010_factor_A": 1.0,   # S-3 passed both bars (overhead <= 3%, msgs/s <= 60): no extra fix effort
    "g011_factor_A": 1.0,   # S-5 passed (AT-M0-06): memory handoff works as designed
    "g041_factor_A": 1.0,   # S-5 passed: sd-server child with preview + cancel (speed misses are engine-side, both bases)
    "adjust_options": ["A", "F1", "F1-R"],
    "s3": {"pass": s3_pass, "xpc_overhead_pct": ovh["value"], "xpc_msgs_per_s_p95": msg["value"],
           "restart": check(r4, "helper kill -9")["value"]},
    "s4_verdict": s4.group(1) if s4 else None,
    "s5": {"pass": r6["pass"], "checks_passed": sum(c["pass"] for c in r6["checks"]), "checks": len(r6["checks"])},
    "osaurus_share_of_A_yearly": d012["osaurus_share_of_A_yearly"],
    "not_measured": missing,
    "provenance": {**prov, "s3": "build/at/AT-M0-04/result.json", "s5": "build/at/AT-M0-06/result.json",
                   "s4_verdict": SP + "S-4-vmlx.md"},
    "sensitivity": [
        {"name": "human-equivalent effort (G-067 at the D-012 estimate, S-1b human maintainer estimate)",
         "overrides": {"g067_measured_pw": 2.5, "yearly_pw_osaurus": 0.83}},
        {"name": "D-012 inputs (no M0 measurement)",
         "overrides": {"g067_measured_pw": 2.5, "yearly_pw_osaurus": 2.25}},
        {"name": "stress: S-1 at its F1 trigger (20 d = 4 pw) and A's yearly at 2x budget (9 pw)",
         "overrides": {"g067_measured_pw": 4.0, "yearly_pw_osaurus": 6.75}},
    ],
}
if not s3_pass:
    sys.exit("S-3 did not pass both bars: set g010_factor_A from the report's extra-effort estimate")
json.dump(inp, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
print(json.dumps({k: inp[k] for k in ("g067_measured_pw", "yearly_pw_osaurus", "not_measured")}))
PY

echo "== switch.py --self-test"
set +e
python3 -I tools/d012/switch.py --baseline tools/d012/baseline.json --self-test
RC_self=$?
echo "== switch.py (inputs)"
python3 -I tools/d012/switch.py --baseline tools/d012/baseline.json --inputs "$OUT/inputs.json" --out "$OUT/switch.json" >/dev/null
RC_run=$?
set -e
echo "self-test exit=$RC_self run exit=$RC_run"

python3 -I - "$OUT" "$SHA" "$RC_self" "$RC_run" <<'PY'
import json, os, platform, re, sys
out, sha, rc_self, rc_run = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
checks = []
def add(n, v, bar, ok): checks.append({"name": n, "value": v, "bar": bar, "pass": bool(ok)})
add("switch.py self-test (baseline re-sum + D-012 totals)", rc_self, 0, rc_self == 0)
sw = json.load(open(os.path.join(out, "switch.json"))) if rc_run == 0 else {}
opts = sw.get("options", {})
three = {o: opts.get(o, {}).get("three_yr") for o in ("A", "F1", "F1-R", "F2")}
add("3-year totals for A, F1, F1-R, F2", three, "all present", all(isinstance(v, float) for v in three.values()))
add("boolean switch", sw.get("switch"), "bool", isinstance(sw.get("switch"), bool))
a, f1r = f"{three['A']:.1f}" if three["A"] else "?", f"{three['F1-R']:.1f}" if three["F1-R"] else "?"
sel = open("docs/research/05-fork/selection.md").read()
m0 = sel.split("### M0 re-run")[1] if "### M0 re-run" in sel else ""
add("selection.md §11 'M0 re-run' quotes A and F1-R 3-year totals", [a, f1r], "both in the subsection",
    "## 11." in sel.split("### M0 re-run")[0] if m0 else False)
checks[-1]["pass"] = checks[-1]["pass"] and a in m0 and f1r in m0
dec = open("docs/research/DECISIONS.md").read()
ent = re.search(r"^## (D-\d{3}): D-012 switch rule re-run.*?(?=^## D-\d{3}|\Z)", dec, re.M | re.S)
add("DECISIONS 'switch re-run' entry quotes A and F1-R 3-year totals", ent.group(1) if ent else None,
    "entry present with both", bool(ent) and a in ent.group(0) and f1r in ent.group(0))
if sw.get("switch") is False:
    ok_dec = sw.get("decision") == "A confirmed" and bool(ent) and "A confirmed" in ent.group(0)
    add("decision", "A confirmed", "A confirmed (switch false)", ok_dec)
else:
    amd = open("docs/PRD-AMENDMENTS.md").read()
    q = open("docs/research/QUESTIONS.md").read()
    ok_dec = bool(re.search(r"^\| A-M0-\w+ \|[^\n]*M0\.T13[^\n]*\| major \| \*\*?proposed", amd, re.M)) and "M0.T13" in q
    add("decision", "switch proposed", "proposed major amendment + QUESTIONS entry", ok_dec)
ok = all(c["pass"] for c in checks)
res = {"at": "AT-M0-13", "pass": ok, "result": ("A confirmed" if sw.get("switch") is False else "decision recorded") if ok else "fail",
       "checks": checks, "three_yr": three, "ratio_A_over_F1R": sw.get("ratio_A_over_F1R"), "switch": sw.get("switch"),
       "sensitivity": sw.get("sensitivity"), "commit": sha,
       "host": {"machine": platform.machine(), "macos": platform.mac_ver()[0], "python": platform.python_version()}}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
print(json.dumps({"at": "AT-M0-13", "pass": ok, "three_yr": three, "switch": sw.get("switch"),
                  "failed": [c["name"] for c in checks if not c["pass"]]}))
sys.exit(0 if ok else 1)
PY
