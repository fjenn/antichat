#!/bin/bash
# fs_usage audit (M1.T20, AT-090 leg 2, R-090 AC2; [PERM: sudo]): records every file-system syscall of the AntiChat
# processes (app, AntiChatEngine helper, llama-server) while CMD runs, then fails when any write-class call
# (write/pwrite/writev, WrData, open with W/C flags, rename, unlink, mkdir, truncate, chmod, link, fsync) touches the
# data folder (~/Library/{Application Support,Caches,Logs,Saved Application State}/AntiChat*|app.antichat*).
# Usage: sudo tools/ci/fs-usage-audit.sh <seconds> -- <command...>
#   Out: build/at/AT-090/fs_usage.log (raw), build/at/AT-090/fs_usage.json (verdict).
# Without root (sudo -n fails) it prints "not run: permission" and exits 77 (PRD §1.5.1: record it in QUESTIONS).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${FS_USAGE_OUT:-$ROOT/build/at/AT-090}"
secs="${1:?seconds}"; shift
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "usage: $0 <seconds> -- <command...>"; exit 64; }
if [ "$(id -u)" != 0 ]; then
  echo "fs-usage-audit: not run: permission (needs root: sudo $0 $secs -- $*)"
  exit 77
fi
mkdir -p "$OUT"
LOG="$OUT/fs_usage.log"
HOME_DIR="${SUDO_USER:+$(eval echo "~$SUDO_USER")}"; HOME_DIR="${HOME_DIR:-$HOME}"
/usr/bin/fs_usage -w -f filesys -t "$secs" AntiChat AntiChatEngine llama-server >"$LOG" 2>&1 &
FSPID=$!
sleep 1
if [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" "$@"; else "$@"; fi
code=$?
kill -INT "$FSPID" 2>/dev/null; wait "$FSPID" 2>/dev/null
python3 -I - "$LOG" "$HOME_DIR" "$OUT/fs_usage.json" "$code" <<'PY'
import json, re, sys
log, home, out, code = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
roots = [f"{home}/Library/{r}/" for r in ("Application Support", "Caches", "Logs", "Saved Application State")]
write_calls = re.compile(r"\b(write|pwrite|writev|pwritev|WrData|rename|renameat|unlink|unlinkat|rmdir|mkdir|mkdirat|"
                         r"ftruncate|truncate|chmod|fchmod|link|symlink|fsync|fcntl\(F_FULLFSYNC\)|clonefile|exchangedata)\b")
open_write = re.compile(r"\bopen(at)?\b.*\(([^)]*)\)")
bad = []
for line in open(log, errors="replace"):
    hit = any(r in line and line.split(r, 1)[1].lower().startswith(("antichat", "app.antichat")) for r in roots)
    if not hit:
        continue
    m = open_write.search(line)
    if write_calls.search(line) or (m and any(c in m.group(2) for c in "WCT")):
        bad.append(line.rstrip())
res = {"pass": not bad and code == 0, "commandExit": code, "writes": bad[:200], "writeCount": len(bad)}
json.dump(res, open(out, "w"), indent=2)
print(f"fs-usage-audit: {len(bad)} write calls under the data folder; command exit {code}; pass={res['pass']}")
sys.exit(0 if res["pass"] else 1)
PY
