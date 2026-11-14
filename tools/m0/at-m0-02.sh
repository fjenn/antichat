#!/usr/bin/env bash
# AT-M0-02 (docs/prd/M0.md, M0.T14; spans T02 + T14; selection.md §9 S-1): Osaurus extraction closure gate.
#  1. make build test-unit
#  2. swift test --filter OsaurusVendoredTests (ported upstream tests; 0 failures, ≥ 1 per subsystem)
#  3. python3 -I tools/ci/vendored-allowlist.py   (zero DENY paths, allow-list only)
#  4. python3 -I tools/ci/patch-lint.py           (marker ↔ row, no unmarked edits)
#  5. effort_days from docs/research/07-spikes/S-1-osaurus-closure.md ≤ 10
#  6. every D-01…D-04, D-08, D-09, D-13 has a row and a marker (D-04: "Not applied" row, A-M0-06)
# Writes build/at/AT-M0-02/{<date>.log,result.json}; exits 0 only on pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-02"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SHA="$(git rev-parse HEAD)"
echo "== AT-M0-02 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA"
[ -n "$(git status --porcelain --untracked-files=no)" ] && echo "note: working tree has uncommitted changes"

run() { # name cmd...
  local name=$1; shift
  echo "== $name: $*"
  set +e; "$@"; local rc=$?; set -e
  echo "== $name exit=$rc"
  eval "RC_${name}=$rc"
}
run build_test_unit make build test-unit
TESTLOG="$(mktemp -t at-m0-02-ovtests)"
ALLOWLOG="$(mktemp -t at-m0-02-allowlist)"
trap 'rm -f "$TESTLOG" "$ALLOWLOG"' EXIT
echo "== ovtests: swift test --disable-keychain --filter OsaurusVendoredTests"
set +e; swift test --disable-keychain --filter OsaurusVendoredTests 2>&1 | tee "$TESTLOG"; RC_ovtests=${PIPESTATUS[0]}; set -e
echo "== ovtests exit=$RC_ovtests"
echo "== allowlist: python3 -I tools/ci/vendored-allowlist.py"
set +e; python3 -I tools/ci/vendored-allowlist.py 2>&1 | tee "$ALLOWLOG"; RC_allowlist=${PIPESTATUS[0]}; set -e
echo "== allowlist exit=$RC_allowlist"
run patchlint python3 -I tools/ci/patch-lint.py

python3 -I - "$OUT" "$SHA" "$RC_build_test_unit" "$RC_ovtests" "$RC_allowlist" "$RC_patchlint" "$TESTLOG" "$ALLOWLOG" <<'PY'
import json, os, platform, re, subprocess, sys
out, sha, rc_bt, rc_ov, rc_al, rc_pl, testlog, allowlog = sys.argv[1:]
rc_bt, rc_ov, rc_al, rc_pl = map(int, (rc_bt, rc_ov, rc_al, rc_pl))
root = os.getcwd()
checks = []
def add(n, v, bar, ok): checks.append({"name": n, "value": v, "bar": bar, "pass": bool(ok)})

add("make_build_test_unit_exit", rc_bt, 0, rc_bt == 0)
log = open(testlog).read()
m = re.search(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)", log)
n_tests = int(m.group(1)) if m else 0
fails = len(re.findall(r"^✘ Test .* failed", log, re.M))
add("ovtests_exit", rc_ov, 0, rc_ov == 0)
add("ovtests_passed", n_tests, "> 0", n_tests > 0 and m and m.group(3) == "passed")
add("ovtests_failures", fails, 0, fails == 0)

# ≥ 1 passing ported test per closure subsystem that has upstream tests.
subsystems = {
    "downloader": "ChunkedFileDownloaderTests",
    "search/readability": "SearchDiagnosticsExtractionTests",
    "documents/emitters": "XLSXEmitterTests",
    "ChipProfile": "ChipProfileTests",
    "MetalGate/ModelLease": "MetalGateTests",
}
for name, suite in subsystems.items():
    files = subprocess.run(["grep", "-rlw", f"struct {suite}", "Vendor/osaurus@2922745/Packages/OsaurusCore/Tests"],
                           capture_output=True, text=True).stdout.split()
    src = open(files[0]).read() if files else ""
    disp = re.search(r'@Suite\("([^"]+)"', src)
    label = disp.group(1) if disp else suite
    passed = re.search(rf'^✔ Suite "?{re.escape(label)}"? passed', log, re.M)
    add(f"ported_tests[{name}]", files[0].split("Tests/", 1)[-1] if files else None, "suite present and passing",
        bool(files) and bool(passed))
add("ported_tests[MCP OAuth]", "not kept (swift-sdk OAuth, K-NEW-GAP-1)", "n/a if not kept", True)

add("vendored_allowlist_exit", rc_al, 0, rc_al == 0)
add("patch_lint_exit", rc_pl, 0, rc_pl == 0)

report = open("docs/research/07-spikes/S-1-osaurus-closure.md").read()
em = re.search(r"^effort_days: ([0-9.]+)\s*$", report, re.M)
days = float(em.group(1)) if em else None
add("effort_days", days, "<= 10", days is not None and days <= 10)

table = open("Vendor/UPSTREAM_PATCHES.md").read()
applied, _, not_applied = table.partition("## Not applied")
markers = subprocess.run(["grep", "-rho", r"ANTICHAT-PATCH: UP-OS-[0-9]*", "Vendor/osaurus@2922745"],
                         capture_output=True, text=True).stdout
dev = {"D-01": "UP-OS-001", "D-02": "UP-OS-002", "D-03": "UP-OS-003", "D-04": "UP-OS-004",
       "D-08": "UP-OS-008", "D-09": "UP-OS-009", "D-13": "UP-OS-013"}
for d, up in dev.items():
    row = re.search(rf"^\| {up} \|.*\b{d}\b", applied, re.M)
    marked = f"ANTICHAT-PATCH: {up}" in markers
    if d == "D-04":
        na = re.search(rf"^\| {up} \| {d}\b", not_applied, re.M)
        add(f"deviation[{d}]", "not applied: MCP OAuth not vendored (A-M0-06)", "row + marker, or Not-applied row",
            bool(na) and not marked)
    else:
        add(f"deviation[{d}]", f"{up} row={'yes' if row else 'no'} marker={'yes' if marked else 'no'}",
            "row + marker", bool(row) and marked)

al = open(allowlog).read()
deny = len(re.findall(r"DENY path", al))
add("deny_paths_vendored", deny, 0, deny == 0)
rows = [l.split("\t")[0] for l in open("Vendor/osaurus-allowlist.tsv") if l.strip() and not l.startswith("#")]
add("closure_files_vendored", rows.count("vendored"), ">= 1 (S-1 count; packet estimate >= 87)", rows.count("vendored") > 0)
add("ported_test_files", rows.count("test"), ">= 1", rows.count("test") > 0)

ok = all(c["pass"] for c in checks)
host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "swift": subprocess.run(["swift", "--version"], capture_output=True, text=True).stdout.splitlines()[0]}
json.dump({"at": "AT-M0-02", "pass": ok, "checks": checks, "commit": sha, "host": host},
          open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
print(json.dumps({"at": "AT-M0-02", "pass": ok, "failed": [c["name"] for c in checks if not c["pass"]]}))
sys.exit(0 if ok else 1)
PY
