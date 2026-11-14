#!/usr/bin/env bash
# AT-M0-12 (M0.T12; selection §9 S-6, S-7): `make m0-gate AT=AT-M0-12`.
#   SIGNING_MODE=adhoc make build-release && tools/release/verify-signing.sh build/release/AntiChat.app
#   && tools/release/sign.sh --mode adhoc --bundle build/runtimes/video-runtime-unzipped && tools/release/appcast-test.sh
# plus the launch check (signed app from /Applications streams a reply through the signed helper + llama-server)
# and the licence check (tools/acknowledgments.py). Writes build/at/AT-M0-12/{<date>.log, result.json,
# codesign-dvvv.txt, spctl.txt, appcast.xml, …}.
# Env: SKIP_BUILD=1 (re-sign + verify the existing build/AntiChat.app instead of rebuilding),
#      RUNTIME_ZIP (default: newest build/runtimes/video-runtime-*.zip, from `make runtime-video`),
#      FIXTURES (default fixtures; tiny GGUF at stub-models/tiny-gguf/tiny.gguf),
#      ACK_BINARIES_SRC (checkout with llama.cpp/ and sdcpp/ sources; default Binaries),
#      SKIP_LAUNCH=1, INSTALL_PATH (default /Applications/AntiChat-M0.app).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT=build/at/AT-M0-12
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
exec > >(tee -a "$LOG") 2>&1
echo "== AT-M0-12 $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD) ($(sw_vers -productVersion), $(xcodebuild -version | head -1))"
APP=build/release/AntiChat.app
INSTALL_PATH="${INSTALL_PATH:-/Applications/AntiChat-M0.app}"
FIXTURES="${FIXTURES:-fixtures}"
R_build=fail R_verify_app=fail R_order=fail R_runtime=fail R_appcast=fail R_launch=skipped R_licences=fail
step() { echo; echo "---- $*"; }

# 1. Release build + inside-out signing + verification
step "1. SIGNING_MODE=adhoc make build-release"
if [ "${SKIP_BUILD:-0}" = 1 ] && [ -d "$APP" ]; then
  rm -f build/release/sign-report.tsv
  tools/release/sign.sh --mode adhoc --app "$APP" --report build/release/sign-report.tsv && R_build=pass || R_build=fail
else
  SIGNING_MODE=adhoc make build-release && R_build=pass || R_build=fail
fi
cp build/release/sign-report.tsv "$OUT/sign-report-app.tsv" 2>/dev/null || true

step "2. verify-signing.sh $APP"
SIGNING_MODE=adhoc tools/release/verify-signing.sh --out "$OUT" "$APP" && R_verify_app=pass || R_verify_app=fail

# Inside-out order: every signed path must come after everything signed inside it.
python3 -I - "$OUT/sign-report-app.tsv" > "$OUT/order-check.txt" <<'PY' && R_order=pass || R_order=fail
import sys
rows = [l.rstrip("\n").split("\t")[0] for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
bad = []
for i, p in enumerate(rows):
    bad += [f"{q} signed after its container {p}" for q in rows[i + 1:] if q.startswith(p.rstrip("/") + "/")]
app_last = rows[-1].endswith(".app") and rows[-1].startswith("/")  # the app is reported by absolute path
if not app_last:
    bad.append(f"last signing step is not the app: {rows[-1]}")
print(f"{len(rows)} signing steps; app signed last: {app_last}; order violations: {len(bad)}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
cat "$OUT/order-check.txt"

# 3. Video runtime zip from M0.T07, re-signed inside-out
step "3. sign.sh --mode adhoc --bundle build/runtimes/video-runtime-unzipped"
RUNTIME_ZIP="${RUNTIME_ZIP:-$(ls -t build/runtimes/video-runtime-*.zip 2>/dev/null | head -1)}"
if [ -n "$RUNTIME_ZIP" ] && [ -f "$RUNTIME_ZIP" ]; then
  echo "runtime zip: $RUNTIME_ZIP ($(shasum -a 256 "$RUNTIME_ZIP" | cut -c1-16)…)"
  rm -rf build/runtimes/video-runtime-unzipped && mkdir -p build/runtimes/video-runtime-unzipped
  ditto -x -k "$RUNTIME_ZIP" build/runtimes/video-runtime-unzipped
  rm -f "$OUT/sign-report-runtime.tsv"
  if tools/release/sign.sh --mode adhoc --bundle build/runtimes/video-runtime-unzipped --report "$OUT/sign-report-runtime.tsv" &&
     SIGNING_MODE=adhoc tools/release/verify-signing.sh --tree --out "$OUT" build/runtimes/video-runtime-unzipped; then
    PY_BIN="$(ls build/runtimes/video-runtime-unzipped/*/bin/python3.1? 2>/dev/null | head -1)"
    if "$PY_BIN" -I -c "import mlx.core as mx, numpy, safetensors, PIL; print('signed runtime python ok, mlx', mx.__version__, (mx.ones(4) * 2).sum().item())"; then
      R_runtime=pass
    else R_runtime=fail; fi
  else R_runtime=fail; fi
else
  echo "no build/runtimes/video-runtime-*.zip (run make runtime-video)"; R_runtime=fail
fi

# 4. Test-key appcast
step "4. appcast-test.sh"
tools/release/appcast-test.sh "$APP" && R_appcast=pass || R_appcast=fail
cp build/updates/appcast.xml "$OUT/appcast.xml" 2>/dev/null || true

# 5. Launch from /Applications, one streamed reply through the signed helper and the signed llama-server.
step "5. launch from $INSTALL_PATH"
R_launch=skipped
if [ "${SKIP_LAUNCH:-0}" != 1 ]; then
  # Dialog guard: a hardened-runtime ad-hoc app whose nested frameworks fail library validation aborts in dyld,
  # and macOS then shows "AntiChat cannot be opened because of a problem" on the user's screen. Refuse to
  # launch unless the static preconditions hold (codesign verify passed; ad-hoc → LV exemption present).
  ENT_APP="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
  ENT_ENG="$(codesign -d --entitlements :- "$APP/Contents/XPCServices/AntiChatEngine.xpc" 2>/dev/null)"
  if [ "${R_verify_app}" != pass ]; then
    echo "launch guard: verify-signing failed; not launching"; R_launch=fail
  elif ls "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/XPCServices/*/Contents/Frameworks/*.framework >/dev/null 2>&1 &&
       ! { grep -q disable-library-validation <<<"$ENT_APP" && grep -q disable-library-validation <<<"$ENT_ENG"; }; then
    echo "launch guard: ad-hoc build with embedded frameworks but no LV exemption → dyld would abort; not launching"; R_launch=fail
  else
    TINY="$ROOT/$FIXTURES/stub-models/tiny-gguf/tiny.gguf"
    [ -f "$TINY" ] || TINY="$ROOT/build/fixtures-t04/stub-models/tiny-gguf/tiny.gguf"
    rm -rf "$INSTALL_PATH" && ditto "$APP" "$INSTALL_PATH"
    QA="$(xattr -lr "$INSTALL_PATH" | grep -c com.apple.quarantine || true)"
    echo "installed $INSTALL_PATH (quarantine attributes: $QA); tiny model $TINY"
    RAW="$ROOT/$OUT/launch-family.jsonl"; rm -f "$RAW"
    MARK="$(date '+%Y-%m-%d %H:%M:%S')"; T0=$(date +%s)
    open -g -j -W -n "$INSTALL_PATH" --args -Bench family --model "gguf:$TINY" --hold 6 --raw "$RAW" &
    OPENPID=$!
    : > "$OUT/launch-ps.txt"
    for _ in $(seq 1 60); do
      ps -axo pid,ppid,command | grep -F "$INSTALL_PATH" | grep -v grep | cut -c1-220 > "$OUT/launch-ps.tmp" || true
      if grep -q "Helpers/llama-server" "$OUT/launch-ps.tmp"; then cp "$OUT/launch-ps.tmp" "$OUT/launch-ps.txt"; break; fi
      sleep 0.5
    done
    rm -f "$OUT/launch-ps.tmp"
    wait "$OPENPID"
    cat "$OUT/launch-ps.txt"
    # New crash reports or AMFI/dyld refusals since the launch = a dialog may have been shown → fail.
    CRASHES="$(find "$HOME/Library/Logs/DiagnosticReports" -newermt "$MARK" \( -name 'AntiChat*' -o -name 'llama-server*' \) 2>/dev/null)"
    log show --start "$MARK" --style compact --predicate \
      '(process == "AntiChat" OR process == "AntiChatEngine" OR process == "llama-server" OR sender == "AMFI" OR process == "amfid") AND (eventMessage CONTAINS[c] "not valid for use in process" OR eventMessage CONTAINS[c] "library validation" OR eventMessage CONTAINS[c] "code signature" OR eventMessage CONTAINS[c] "Library not loaded")' \
      > "$OUT/launch-log.txt" 2>&1 || true
    REFUSALS="$(grep -vc -E '^(Timestamp|Filtering|$)' "$OUT/launch-log.txt" || true)"
    python3 -I - "$RAW" "$OUT/launch-ps.txt" "$INSTALL_PATH" "$CRASHES" "$REFUSALS" "$QA" "$(( $(date +%s) - T0 ))" > "$OUT/launch.json" <<'PY'
import json, os, sys
raw, ps, inst, crashes, refusals, qa, secs = sys.argv[1:]
rows = [json.loads(l) for l in open(raw)] if os.path.exists(raw) else []
r = rows[-1] if rows else {}
pst = open(ps).read()
res = {"install_path": inst, "generates": bool(r.get("generates")), "tokens": r.get("tokens"), "loads": r.get("loads"),
       "error": r.get("error"), "helper_pid": r.get("helper_pid"),
       "helper_from_install": f"{inst}/Contents/XPCServices/AntiChatEngine.xpc" in pst,
       "llama_server_from_install": f"{inst}/Contents/Helpers/llama-server" in pst,
       "new_crash_reports": [c for c in crashes.split("\n") if c], "lv_refusal_log_lines": int(refusals or 0),
       "quarantine_attributes": int(qa or 0), "elapsed_s": int(secs)}
res["pass"] = (res["generates"] and res["helper_from_install"] and res["llama_server_from_install"]
               and not res["new_crash_reports"] and res["lv_refusal_log_lines"] == 0 and res["quarantine_attributes"] == 0)
print(json.dumps(res, indent=2))
PY
    cat "$OUT/launch.json"
    python3 -I -c "import json,sys; sys.exit(0 if json.load(open('$OUT/launch.json'))['pass'] else 1)" && R_launch=pass || R_launch=fail
  fi
fi

# 6. Licences (S-7)
step "6. tools/acknowledgments.py"
python3 -I tools/acknowledgments.py --binaries-src "${ACK_BINARIES_SRC:-Binaries}" --json "$OUT/acknowledgments.json" > "$OUT/acknowledgments.txt" 2>&1 && R_licences=pass || R_licences=fail
tail -4 "$OUT/acknowledgments.txt"

# result.json
python3 -I - "$OUT" "$(git rev-parse HEAD)" "${R_build}" "${R_verify_app}" "${R_order}" "${R_runtime}" "${R_appcast}" "${R_launch}" "${R_licences}" <<'PY'
import json, os, platform, subprocess, sys
out, commit, build, verify_app, order, runtime, appcast, launch, licences = sys.argv[1:]
v = json.load(open(os.path.join(out, "verify.json"))) if os.path.exists(os.path.join(out, "verify.json")) else {}
ack = json.load(open(os.path.join(out, "acknowledgments.json"))) if os.path.exists(os.path.join(out, "acknowledgments.json")) else {}
la = json.load(open(os.path.join(out, "launch.json"))) if os.path.exists(os.path.join(out, "launch.json")) else {}
spctl = open(os.path.join(out, "spctl.txt")).read() if os.path.exists(os.path.join(out, "spctl.txt")) else ""
checks = [
    {"name": "SIGNING_MODE=adhoc make build-release (xcodebuild Release, CODE_SIGNING_ALLOWED=NO → sign.sh inside-out)", "pass": build == "pass"},
    {"name": "app: every Mach-O signed, one ad-hoc identity, runtime flag; codesign --verify --strict --deep exit 0; zero quarantine",
     "value": v.get("app"), "pass": verify_app == "pass"},
    {"name": "app: inside-out order (nothing signed after its container; app last)", "pass": order == "pass"},
    {"name": "spctl -a -vv recorded, rejected only for the ad-hoc/unnotarized reason", "value": (v.get("app") or {}).get("spctl"),
     "excerpt": spctl.strip().splitlines()[:2], "pass": (v.get("app") or {}).get("spctl") == "rejected-expected"},
    {"name": "video runtime: every Mach-O re-signed inside-out (ad-hoc, runtime flag), verifies; signed python imports mlx",
     "value": v.get("tree"), "pass": runtime == "pass"},
    {"name": "signed app launches from /Applications and streams a reply through the signed helper and llama-server (no crash/LV refusal)",
     "value": la or launch, "pass": launch == "pass"},
    {"name": "test-key appcast signature verifies (sign_update --verify; tampered copy rejected)", "pass": appcast == "pass"},
    {"name": "VENDORED.json licence for every vendored file; ACKNOWLEDGMENTS.md generated without UNKNOWN",
     "value": {"errors": ack.get("errors"), "vendored_rows": (ack.get("vendor_check") or {}).get("rows")}, "pass": licences == "pass"},
]
host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
res = {"at": "AT-M0-12", "pass": all(c["pass"] for c in checks), "checks": checks, "commit": commit, "host": host,
       "amendments": ["A-M0-T12a", "A-M0-T12b"]}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2, default=str)
for c in checks:
    print(("[ok]  " if c["pass"] else "[FAIL]") + " " + c["name"])
print("AT-M0-12 pass =", res["pass"])
sys.exit(0 if res["pass"] else 1)
PY
