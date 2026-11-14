#!/usr/bin/env bash
# AT-VQ-M0 (docs/prd/M0.md, M0.T15): checks the outputs of the visual QA runbook tools/visual/vq-00-m0-proof.md.
#  1. every listed screenshot exists in build/visual/m0/
#  2. build/visual/m0/findings.md exists, lists every checkpoint, and has no `fail`
#  3. hard check H5: `engine.restarted` and `voice.permission` copy in the app sources match copy-deck.md verbatim
# Writes build/at/AT-VQ-M0/{<date>.log,result.json}; exits 0 only on pass. When no capture exists yet the result is
# `pending` (exit 2): the run needs computer use (P-CU), which the user grants once (runbook preconditions).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-VQ-M0"
VIS="$ROOT/build/visual/m0"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SHA="$(git rev-parse HEAD)"
echo "== AT-VQ-M0 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA"

set +e
python3 -I - "$VIS" "$OUT/result.json" "$SHA" <<'PY'
import json, os, re, sys
vis, out, sha = sys.argv[1:4]
shots = ["A1-idle", "A2-streaming", "A3-after-kill", "A4-recovered",
         "A5-dark-A1", "A5-dark-A2", "A5-dark-A3", "A5-dark-A4",
         "B2-tcc-prompt", "B3-tcc-list", "C1-gatekeeper", "C2-running"]
points = ["A1", "A2", "A3", "A4", "A5", "B2", "B3", "C1", "C2"]
checks = []

def chk(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {value} (bar: {bar})")

# 3. H5 copy sync (static; runs even before the visual run)
deck = open("docs/research/10-architecture/design-system/copy-deck.md", encoding="utf-8").read()
def deck_text(key):
    m = re.search(rf"^\| `{re.escape(key)}` \|(.*)$", deck, re.M)
    cells = [c.strip() for c in m.group(1).split("|")] if m else []
    return cells
er = deck_text("engine.restarted")   # | message | The AI engine restarted. | Retry |
vp = deck_text("voice.permission")   # | AntiChat needs the microphone ... |
er_text = er[1] if len(er) > 1 else None
vp_text = vp[0] if vp else None
view = open("Packages/UI/Sources/AntiChatUI/Spike/SpikeChatView.swift", encoding="utf-8").read()
plist = open("App/AntiChat/Info.plist", encoding="utf-8").read()
yml = open("project.yml", encoding="utf-8").read()
chk("H5 engine.restarted copy in SpikeChatView", er_text, "copy-deck verbatim",
    er_text is not None and f'Text("{er_text}")' in view)
chk("H5 engine.restarted action label Retry", er[2] if len(er) > 2 else None, "Retry",
    len(er) > 2 and er[2] == "Retry" and '"Retry"' in view)
chk("H5 voice.permission = NSMicrophoneUsageDescription (Info.plist + project.yml)", vp_text, "copy-deck verbatim",
    vp_text is not None and f"<string>{vp_text}</string>" in plist and f'"{vp_text}"' in yml)

# 1. screenshots
have = [s for s in shots if os.path.isfile(os.path.join(vis, s + ".png"))]
missing = [s for s in shots if s not in have]
chk("screenshots present in build/visual/m0", f"{len(have)}/{len(shots)}", "all", not missing)

# 2. findings
fp = os.path.join(vis, "findings.md")
if os.path.isfile(fp):
    txt = open(fp, encoding="utf-8").read()
    fails = re.findall(r"^- (\S+) fail\b", txt, re.M)
    listed = set(re.findall(r"^- (\S+) (?:pass|fail)\b", txt, re.M))
    chk("findings.md lists every checkpoint", sorted(listed), points, set(points) <= listed)
    chk("findings.md has no fail", fails, "[]", not fails)
else:
    chk("findings.md exists", False, True, False)

static_ok = all(c["pass"] for c in checks if c["name"].startswith("H5"))
if not have and not os.path.isfile(fp):
    status = "pending" if static_ok else "fail"
else:
    status = "pass" if all(c["pass"] for c in checks) else "fail"
res = {"at": "AT-VQ-M0", "pass": status == "pass", "status": status, "checks": checks, "commit": sha,
       "missing_screenshots": missing,
       "note": "pending = visual run not executed yet (needs computer use, P-CU); see tools/visual/vq-00-m0-proof.md"}
json.dump(res, open(out, "w"), indent=2)
print(f"== AT-VQ-M0 {status.upper()}")
sys.exit({"pass": 0, "pending": 2}.get(status, 1))
PY
rc=$?
set -e
exit $rc
