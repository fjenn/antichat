#!/bin/bash
# AT-NFR-D8 (M8.T10): Settings › Storage sizes vs `du -sk` within 1 %. Reads `antichat-cli storage --json` over a
# container (default the Debug container, or --container / ANTICHAT_DEV_CONTAINER) and compares the total and the
# documented-path sum with `du -sk × 1024` over the same DataPaths. Writes build/at/AT-NFR-D8/<date>.json.
#   tools/ci/storage-accuracy.sh [--container <dir>]
set -euo pipefail
cd "$(dirname "$0")/../.."
container="${ANTICHAT_DEV_CONTAINER:-$HOME/Library/Application Support/AntiChat-Dev}"
[ "${1:-}" = "--container" ] && container="$2"
swift build --product antichat-cli -q 2>/dev/null || swift build --product antichat-cli
bin="$(swift build --product antichat-cli --show-bin-path)/antichat-cli"
json="$("$bin" storage --json --container "$container")"
out="build/at/AT-NFR-D8/$(date +%F).json"
mkdir -p "$(dirname "$out")"
python3 -I - "$json" "$out" <<'PY'
import json, subprocess, sys
r = json.loads(sys.argv[1])
paths = [p for p in r["paths"] if __import__("os").path.lexists(p)]
du = int(subprocess.run(["du", "-skc", *paths], capture_output=True, text=True).stdout.strip().splitlines()[-1].split()[0]) * 1024 if paths else 0
cats = {k: v for k, v in r.items() if k not in ("total", "paths")}
ok = abs(r["total"] - du) <= 0.01 * max(du, 1) and sum(cats.values()) == r["total"]
rep = {"total": r["total"], "du": du, "delta_pct": round(100 * (r["total"] - du) / max(du, 1), 3), "categories": cats, "pass": ok}
open(sys.argv[2], "w").write(json.dumps(rep, indent=2, sort_keys=True))
print(json.dumps(rep, sort_keys=True))
sys.exit(0 if ok else 1)
PY
