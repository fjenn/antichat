#!/usr/bin/env bash
# AT-M0-03 (docs/prd/M0.md, M0.T03; upstream.md §7): vendor-sync rehearsal over >= 6 months of upstream.
#  1. build/at/AT-M0-03/plan.json: >= 6 bumps (sha_1..sha_6) covering >= 183 days, sha_6 = the pinned head
#  2. per bump k = 1..6 (and the backport, k = 0): bump-<k>.log + bump-<k>.json exist; closure build, ported
#     tests (OsaurusVendoredTests) and patch-lint green; every active UP row has >= 1 marker
#  3. final bump: distinct markers = UPSTREAM_PATCHES.md marker rows on main; root build + test green
#  4. head equality: `diff -r` of Vendor/osaurus@2922745 on main vs the rehearsal branch's final tree is empty
#  5. docs/research/07-spikes/S-1-vendor-sync.md: median_bump_days <= 1 (and equal to the bump JSONs' median)
# Writes build/at/AT-M0-03/{<date>.log,result.json}; exits 0 only on pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-03"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
BRANCH="${REHEARSAL_BRANCH:-spike/s-1-vendor-sync}"
SHA="$(git rev-parse HEAD)"
echo "== AT-M0-03 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA, rehearsal branch $BRANCH"
SHORT="$(python3 -I -c 'import json;print(json.load(open("Vendor/donors.json"))["osaurus"]["ref"][:7])')"
A="$(mktemp -d)"; B="$(mktemp -d)"
trap 'rm -rf "$A" "$B"' EXIT
git archive HEAD "Vendor/osaurus@$SHORT" | tar -x -C "$A"
RC_branch=0
git rev-parse --verify -q "$BRANCH" >/dev/null || RC_branch=1
if [ "$RC_branch" = 0 ]; then
  git archive "$BRANCH" "Vendor/osaurus@$SHORT" | tar -x -C "$B" || RC_branch=1
fi
echo "== diff -r HEAD:Vendor/osaurus@$SHORT $BRANCH:Vendor/osaurus@$SHORT"
set +e; diff -r "$A/Vendor/osaurus@$SHORT" "$B/Vendor/osaurus@$SHORT" | head -40; RC_diff=${PIPESTATUS[0]}; set -e
[ "$RC_branch" = 0 ] || RC_diff=2
echo "== diff exit=$RC_diff"
BRANCH_SHA="$(git rev-parse --verify -q "$BRANCH" || echo none)"

python3 -I - "$OUT" "$SHA" "$RC_diff" "$BRANCH" "$BRANCH_SHA" "$SHORT" <<'PY'
import json, os, platform, re, statistics, subprocess, sys
out, sha, rc_diff, branch, branch_sha, short = sys.argv[1:]
checks = []
def add(n, v, bar, ok): checks.append({"name": n, "value": v, "bar": bar, "pass": bool(ok)})

plan = json.load(open(os.path.join(out, "plan.json")))
steps = plan["steps"]
donor_ref = json.load(open("Vendor/donors.json"))["osaurus"]["ref"]
add("bumps_replayed", len(steps) - 1, ">= 6", len(steps) - 1 >= 6)
add("coverage_days", plan["span_days"], ">= 183", plan["span_days"] >= 183)
add("sha_last_is_pinned_head", steps[-1]["sha"][:7], donor_ref[:7], steps[-1]["sha"] == donor_ref)

bumps = []
for st in steps:
    k = st["k"]
    jf, lf = os.path.join(out, f"bump-{k}.json"), os.path.join(out, f"bump-{k}.log")
    b = json.load(open(jf)) if os.path.exists(jf) else None
    ok = bool(b) and os.path.exists(lf) and b["ref"] == st["sha"] and b["closure_build_exit"] == 0 \
        and b["closure_tests_exit"] == 0 and b["tests"]["result"] == "passed" and b["patch_lint_exit"] == 0 \
        and b["markers_ok"] and b["green"]
    add(f"bump[{k}]", None if not b else {"ref": b["short"], "tests": b["tests"]["tests"], "lint": b["patch_lint_exit"],
        "active_marker_rows": b["active_marker_rows"], "minutes": b["active_minutes"]},
        "log + closure build/tests/patch-lint green + markers", ok)
    if b:
        bumps.append(b)

table = open("Vendor/UPSTREAM_PATCHES.md").read().split("## Not applied")[0]
rows = re.findall(r"^\| (UP-[A-Z]+-\d{3}) \| [^|]+ \| [^|]+ \| ([^|]+) \|", table, re.M)
marker_rows = sorted(u for u, kind in rows if kind.strip() != "access")
last = bumps[-1] if bumps else {}
add("final_markers_equal_rows", last.get("distinct_markers"), len(marker_rows),
    last.get("distinct_markers") == len(marker_rows) and sorted(last.get("marker_counts", {})) == marker_rows)
add("final_root_build_and_tests", [last.get("root_build_exit"), last.get("root_tests_exit")], [0, 0],
    last.get("root_build_exit") == 0 and last.get("root_tests_exit") == 0)
add("final_diff_r_in_rehearsal", last.get("diff_r_empty"), True, last.get("diff_r_empty") is True)
add("head_equality_diff_r", int(rc_diff), 0, int(rc_diff) == 0)

report = open("docs/research/07-spikes/S-1-vendor-sync.md").read()
m = re.search(r"^median_bump_days: ([0-9.]+)\s*$", report, re.M)
y = re.search(r"^yearly_pw_osaurus: ([0-9.]+)\s*$", report, re.M)
days = float(m.group(1)) if m else None
mins = [b["active_minutes"] for b in bumps if b["k"] >= 1]
recomputed = round(statistics.median(mins) / 480, 4) if mins else None
add("median_bump_days", days, "<= 1", days is not None and days <= 1)
add("median_matches_bump_logs", recomputed, days, days is not None and recomputed is not None and abs(recomputed - days) < 1e-3)
add("yearly_pw_osaurus_line", float(y.group(1)) if y else None, "present", bool(y))

ok = all(c["pass"] for c in checks)
host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "swift": subprocess.run(["swift", "--version"], capture_output=True, text=True).stdout.splitlines()[0]}
json.dump({"at": "AT-M0-03", "pass": ok, "checks": checks, "commit": sha, "rehearsal_branch": f"{branch}@{branch_sha}",
           "host": host}, open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
print(json.dumps({"at": "AT-M0-03", "pass": ok, "failed": [c["name"] for c in checks if not c["pass"]]}))
sys.exit(0 if ok else 1)
PY
