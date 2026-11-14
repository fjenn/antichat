#!/usr/bin/env bash
# AT-M0-00: M0 entry check (docs/prd/M0.md, M0.T00).
# Writes build/at/AT-M0-00/{host.json,<date>.log,result.json}; exits 0 only if pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-00"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "== AT-M0-00 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "== step 1: host facts"
tools/m0/host-facts.sh "$OUT" >/dev/null
cat "$OUT/host.json"

probe() { # name, command...
  local name="$1"; shift
  echo "== probe $name: $*"
  if "$@" >"$OUT/probe-$name.out" 2>&1; then
    echo "granted"; echo "$name=granted" >> "$OUT/probes.txt"
  else
    echo "refused (exit $?)"; echo "$name=refused" >> "$OUT/probes.txt"
  fi
  sed 's/^/    /' "$OUT/probe-$name.out" | head -20
}
: > "$OUT/probes.txt"
echo "== step 2: permission probes"
probe P-CLONE git ls-remote https://github.com/ggml-org/llama.cpp b11669
probe P-BUILD bash -c 'swift --version && echo "print(\"ok\")" > /tmp/m0.swift && swift /tmp/m0.swift'
probe P-NET curl -fsSI https://huggingface.co/api/models/mlx-community/Qwen3.5-0.8B-MLX-4bit
probe P-ADMIN sudo -n true
probe P-PRIV test -d "$HOME/AntiChatPrivateFixtures/csc"
# P-CU is a computer-use tool call (list_granted_applications), not a shell command.
# The agent records its outcome in p-cu.json ({"status":"granted|refused|n/a","detail":...}).
if [ -f "$OUT/p-cu.json" ]; then
  echo "== probe P-CU (agent tool call): $(cat "$OUT/p-cu.json")"
else
  echo "== probe P-CU: not recorded (agent tool call)"
fi

echo "== evaluate"
python3 -I - "$OUT" "$(git rev-parse HEAD 2>/dev/null || echo none)" <<'PY'
import json, sys, os
out, sha = sys.argv[1], sys.argv[2]
host = json.load(open(os.path.join(out, "host.json")))
probes = dict(l.strip().split("=", 1) for l in open(os.path.join(out, "probes.txt")) if "=" in l)
cu = {"status": "n/a", "detail": "not recorded"}
p = os.path.join(out, "p-cu.json")
if os.path.exists(p):
    cu = json.load(open(p))
probes["P-CU"] = cu.get("status", "n/a")

def ver(s):
    return tuple(int(x) for x in s.split(".") if x.isdigit())
checks = []
def add(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})
add("arch", host["arch"], "arm64", host["arch"] == "arm64")
add("macos", host["macos_version"], ">= 26.4", ver(host["macos_version"]) >= (26, 4))
xc0 = (host["xcodebuild_version"] or [""])[0]
add("xcode", xc0, "Xcode 27.1", xc0.strip() == "Xcode 27.1")
add("free_disk_gb", host["free_disk_gb"], ">= 150", (host["free_disk_gb"] or 0) >= 150)
for k in ("P-CLONE", "P-BUILD", "P-NET"):
    add(k, probes.get(k, "missing"), "granted", probes.get(k) == "granted")
for k in ("P-ADMIN", "P-PRIV", "P-CU"):
    v = probes.get(k, "missing")
    add(k, v, "recorded (any status)", v in ("granted", "refused", "n/a"))
ok = all(c["pass"] for c in checks)
res = {"at": "AT-M0-00", "pass": ok, "checks": checks, "commit": sha,
       "host": {k: host[k] for k in ("macos_version", "macos_build", "arch", "cpu", "mem_bytes", "gpu", "free_disk_gb")},
       "p_cu_detail": cu.get("detail")}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
for c in checks:
    print(f"{'PASS' if c['pass'] else 'FAIL'}  {c['name']}: {c['value']} (bar {c['bar']})")
print("AT-M0-00", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
