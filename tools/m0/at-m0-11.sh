#!/usr/bin/env bash
# AT-M0-11 (docs/prd/M0.md, M0.T11; S-13; P-platform-10): ChatGPT/Claude export import prototype gate.
#  1. swift test --filter ImportRoundTripTests: every fixture under fixtures/chats/{chatgpt-export,claude-export}/
#     imports into GRDB and re-reads with node count, every parent edge, active leaf and active path equal to
#     its *.expected.json (0 differences, no branch dropped)
#  2. make-claude-export.py regenerates the Claude fixture byte-identically (seed 20261030)
#  3. the fixture files match fixtures/fixtures.lock.json
# Writes build/at/AT-M0-11/{<date>.log,result.json,fixtures/*.result.json}; exits 0 only on pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-11"
mkdir -p "$OUT"
rm -rf "$OUT/fixtures"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SHA="$(git rev-parse HEAD)"
FIXSHA="$(git -C fixtures rev-parse HEAD 2>/dev/null || echo none)"
echo "== AT-M0-11 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA fixtures $FIXSHA"
[ -n "$(git status --porcelain --untracked-files=no)" ] && echo "note: working tree has uncommitted changes"

TESTLOG="$(mktemp -t at-m0-11-tests)"
REGEN="$(mktemp -d -t at-m0-11-regen)"
trap 'rm -rf "$TESTLOG" "$REGEN"' EXIT

echo "== tests: swift test --disable-keychain --force-resolved-versions --filter ImportRoundTripTests"
set +e
AT_M0_11_OUT="$OUT" swift test --disable-keychain --force-resolved-versions --filter ImportRoundTripTests 2>&1 | tee "$TESTLOG"
RC_tests=${PIPESTATUS[0]}
set -e
echo "== tests exit=$RC_tests"

echo "== regen: python3 -I tools/fixtures/make-claude-export.py --out $REGEN"
set +e; python3 -I tools/fixtures/make-claude-export.py --out "$REGEN"; RC_regen=$?; set -e
echo "== lock: tools/fixtures/lock.py check of the chats/{chatgpt-export,claude-export} rows of fixtures/fixtures.lock.json"
set +e
python3 -I - fixtures/fixtures.lock.json "$REGEN/lock.json" <<'PY'
import json, subprocess, sys
# Check only the chats/{chatgpt-export,claude-export} rows of the lock (other folders may hold LFS pointers).
lock = json.load(open(sys.argv[1]))["files"]
sub = {k: v for k, v in lock.items() if k.startswith(("chats/chatgpt-export/", "chats/claude-export/"))}
json.dump({"version": 1, "files": sub}, open(sys.argv[2], "w"))
PY
python3 -I tools/fixtures/lock.py check fixtures "$REGEN/lock.json" --only chats/chatgpt-export --only chats/claude-export
RC_lock=$?
set -e
echo "== lock exit=$RC_lock"

python3 -I - "$OUT" "$SHA" "$FIXSHA" "$RC_tests" "$RC_regen" "$RC_lock" "$TESTLOG" "$REGEN" <<'PY'
import glob, hashlib, json, os, platform, re, subprocess, sys
out, sha, fixsha, rc_t, rc_r, rc_l, testlog, regen = sys.argv[1:]
rc_t, rc_r, rc_l = map(int, (rc_t, rc_r, rc_l))
checks = []
def add(n, v, bar, ok): checks.append({"name": n, "value": v, "bar": bar, "pass": bool(ok)})
log = open(testlog).read()
m = re.search(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)", log)
add("swift_test_exit", rc_t, 0, rc_t == 0)
add("tests_passed", int(m.group(1)) if m else 0, ">= 5 (round trip + repair)", m and m.group(3) == "passed" and int(m.group(1)) >= 5)
add("test_issues", len(re.findall(r"^✘ Test .* recorded an issue", log, re.M)), 0,
    not re.search(r"^✘ ", log, re.M))

expected = sorted(glob.glob("fixtures/chats/chatgpt-export/*.expected.json") + glob.glob("fixtures/chats/claude-export/*.expected.json"))
add("fixtures_with_expected", len(expected), ">= 4 (3 ChatGPT + 1 Claude)", len(expected) >= 4)
for e in expected:
    want = json.load(open(e))
    res_path = os.path.join(out, "fixtures", os.path.basename(e).replace(".expected.json", ".result.json"))
    got = json.load(open(res_path)) if os.path.exists(res_path) else None
    convs = {c["conversation"]: c for c in (got or {}).get("conversations", [])}
    for c in want["conversations"]:
        g = convs.get(c["id"])
        name = f"{os.path.basename(e).replace('.expected.json', '')}[{c.get('key', c['id'][:8])}]"
        value = None if g is None else {k: g[k] for k in ("nodes", "edges", "branch_points", "active_path", "recovered", "differences")}
        ok = g is not None and g["differences"] == 0 and g["nodes"] == c["nodes"] and g["edges"] == len(c["edges"]) \
            and g["active_path"] == len(c["active_path"])
        add(name, value, f"0 differences vs expected (nodes {c['nodes']}, edges {len(c['edges'])}, path {len(c['active_path'])})", ok)

def h(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
same = rc_r == 0 and all(h(os.path.join(regen, f)) == h(os.path.join("fixtures/chats/claude-export", f))
                         for f in ("synthetic-branches.zip", "synthetic-branches.expected.json"))
add("claude_fixture_regenerates_identically", same, True, same)
add("fixtures_lock_check_exit", rc_l, 0, rc_l == 0)

ok = all(c["pass"] for c in checks)
host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "swift": subprocess.run(["swift", "--version"], capture_output=True, text=True).stdout.splitlines()[0]}
json.dump({"at": "AT-M0-11", "pass": ok, "checks": checks, "commit": sha, "fixtures_commit": fixsha, "host": host},
          open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
print(json.dumps({"at": "AT-M0-11", "pass": ok, "failed": [c["name"] for c in checks if not c["pass"]]}))
sys.exit(0 if ok else 1)
PY
