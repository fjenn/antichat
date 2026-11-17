#!/bin/bash
# Security proof of the RELEASE-signed File tools services (M6.T17/T18/T19, AT-018 check 2, AT-NFR-SEC3; A-M6-11).
#   tools/at/ft-release-probe.sh [--mode adhoc|devid] [--suite REPS]
# Run after `make build-release` (build/release/AntiChat.app since M10.T01; FT_PROBE_APP overrides; any signing). The probe NEVER launches the shipped bundle ids:
#   macOS ties an App Sandbox container to the code identity that created it, and a service launched under the same
#   bundle id with another signature (ad-hoc dev build vs sign.sh vs Developer ID) makes secinitd show the owner a
#   "differs from previously opened versions … access data" consent dialog and blocks every sandboxed launch until it
#   is answered (2026-11-08). So the probe host is a copy whose app and every slot service carry their own bundle ids,
#   PROBE_ID = app.antichat.AntiChat.relprobe-<mode>[.FileTools[.Net].slot<k>], one id per signing identity (registry
#   ~/Library/Caches/AntiChat-tests/signing-identities.tsv refuses an id seen with another identity), and the copy is
#   signed by tools/release/sign.sh --mode <mode> exactly like the release (same entitlement files).
#   1. entitlements of the probe host's slot services == App/FileToolsHelper/FileTools[Net].entitlements exactly (and
#      the shipped build's too), sbpl deny rules present, no absolute-path / mach-lookup / get-task-allow / exemptions;
#      every slot (A-M6-T21a (a): AntiChatFileTools[Net]Slot1…3.xpc) answers sandboxed, with its variant's network flag;
#   2. the jail probes (Python + raw libc) through both variants on the signed runtime zip, unpacked into the Release
#      Runtimes root (removed again afterwards when this script created it), plus the cross-slot probe (a chat in one
#      slot gets EPERM on every path of another slot's chat jail and container);
#   3. --suite REPS: the AT-NFR-SEC3 fixtures (fixtures/sandbox/security, expected.json) REPS times each.
# Every read outside the jail/Runtimes, every write outside the jail, every socket of the default variant (incl.
# loopback, bind) must be EPERM; the Net variant may connect (loopback → ECONNREFUSED) but still not bind or read.
# Output: build/at/AT-018/<date>/release-<mode>/{entitlements.txt,identity.txt,probe.json,verdict.txt}
#         build/at/AT-NFR-SEC3/<date>/release-<mode>/suite.json; exit 0 = all pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${FT_PROBE_APP:-$ROOT/build/release/AntiChat.app}"
MODE=adhoc; SUITE=0
while (($#)); do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    *) echo "usage: $0 [--mode adhoc|devid] [--suite REPS]" >&2; exit 2 ;;
  esac
done
case "$MODE" in adhoc|devid) ;; *) echo "mode: adhoc|devid" >&2; exit 2 ;; esac
OUT="$ROOT/build/at/AT-018/$(date -u +%F)/release-$MODE"
SUITE_OUT="$ROOT/build/at/AT-NFR-SEC3/$(date -u +%F)/release-$MODE"
WORK="${FT_PROBE_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ft-release-probe.XXXXXX")}"
mkdir -p "$OUT" "$WORK"
fail() { echo "ft-release-probe: $*" >&2; exit 1; }
SHIPPED_ID="app.antichat.AntiChat"
PROBE_ID="app.antichat.AntiChat.relprobe-$MODE"
SLOTS=$(sed -n 's/.*static let maxSlots = \([0-9]*\).*/\1/p' "$ROOT/Packages/EngineProtocol/Sources/AntiChatEngineProtocol/FileTools/FileToolsMessages.swift")
[ -n "$SLOTS" ] || { echo "ft-release-probe: maxSlots not found" >&2; exit 1; }
SLOT_BUNDLES=()  # AntiChatFileTools[Net]Slot<k> (A-M6-T21a (a))
for v in "" Net; do for k in $(seq 1 "$SLOTS"); do SLOT_BUNDLES+=("AntiChatFileTools${v}Slot$k"); done; done

[ -d "$APP" ] || fail "missing $APP (make build-release)"
bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
[ "$bid" = "$SHIPPED_ID" ] || fail "$APP is not the Release app (bundle id $bid): run make build-release"

# 1a. The shipped build's entitlements (read only; nothing of it is launched).
check_ents() {  # check_ents <app> <label>
  local name v xpc got want bad
  for name in "${SLOT_BUNDLES[@]}"; do
    case "$name" in AntiChatFileToolsNet*) v=Net ;; *) v="" ;; esac
    xpc="$1/Contents/XPCServices/$name.xpc"
    [ -d "$xpc" ] || fail "$2 lacks $name.xpc"
    got=$(codesign -d --entitlements :- "$xpc" 2>/dev/null | plutil -convert json -o - -)
    want=$(plutil -convert json -o - "$ROOT/App/FileToolsHelper/FileTools$v.entitlements")
    { echo "## $name.xpc ($2)"; codesign -d --entitlements :- "$xpc" 2>/dev/null; echo
      codesign -dvv "$xpc" 2>&1 | grep -E "^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Runtime)"; echo; } >> "$OUT/entitlements.txt"
    python3 -I -c 'import json,sys; a,b=json.loads(sys.argv[1]),json.loads(sys.argv[2]); sys.exit(0 if a==b else 1)' "$got" "$want" \
      || fail "$2 $name.xpc entitlements differ from FileTools$v.entitlements: $got"
    for bad in absolute-path mach-lookup get-task-allow disable-library-validation read-write user-selected; do
      ! grep -q "$bad" <<<"$got" || fail "$2 $name.xpc carries $bad"
    done
    grep -q "temporary-exception.sbpl" <<<"$got" || fail "$2 $name.xpc lacks the sbpl deny rules (A-M6-T18b)"
  done
  ! ls -d "$1"/Contents/XPCServices/AntiChatFileTools*.xpc 2>/dev/null | grep -vE "/AntiChatFileTools(Net)?Slot[0-9]+\.xpc$" \
    || fail "$2 embeds a File tools service outside the slot set"
}
: > "$OUT/entitlements.txt"
check_ents "$APP" "${APP#$ROOT/}"

# 2. Probe host: own bundle ids, signed by sign.sh in this mode.
# FileToolsClient's two app-wide lookups (the defaults store, Offline only), as one-line stand-ins: the probe passes
# `network:` itself and has no Offline only switch.
stub() { printf '%s\n' "$2" > "$1.swift" && xcrun swiftc -parse-as-library -wmo -emit-module -emit-object -module-name "$1" -o "$1.o" "$1.swift"; }
EP="$ROOT/Packages/EngineProtocol/Sources/AntiChatEngineProtocol/FileTools"
TF="$ROOT/Packages/Tools/Sources/AntiChatTools/FileTools"
( cd "$WORK" && xcrun swiftc -parse-as-library -wmo -emit-module -emit-object -module-name AntiChatEngineProtocol \
    -o AntiChatEngineProtocol.o "$EP/FileToolsMessages.swift" "$EP/FileToolsWire.swift" \
  && stub AntiChatFoundation 'import Foundation
public enum AppDefaults { public static var standard: UserDefaults { .standard } }' \
  && stub AntiChatNetwork 'public final class NetworkPolicyStore: Sendable {
  public static let shared = NetworkPolicyStore(); public var offlineOnly: Bool { false } }' \
  && xcrun swiftc -O -I . -o probe "$ROOT/tools/at/ft-release-probe/main.swift" \
    "$TF/FileToolsClient.swift" "$TF/FileToolsSlots.swift" "$TF/SessionIdleReaper.swift" "$TF/SandboxNotice.swift" \
    AntiChatEngineProtocol.o AntiChatFoundation.o AntiChatNetwork.o ) \
  || fail "probe build failed"
HOST="$WORK/host/AntiChat.app"
rm -rf "$WORK/host"; mkdir -p "$WORK/host"
ditto "$APP" "$HOST"
cp "$WORK/probe" "$HOST/Contents/MacOS/AntiChat"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PROBE_ID" "$HOST/Contents/Info.plist"
for v in "" Net; do
  for k in $(seq 1 "$SLOTS"); do
    sid="$PROBE_ID.FileTools${v:+.$v}.slot$k"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $sid" "$HOST/Contents/XPCServices/AntiChatFileTools${v}Slot$k.xpc/Contents/Info.plist"
  done
done
"$ROOT/tools/release/sign.sh" --mode "$MODE" --app "$HOST" --report "$WORK/sign-report.tsv" > "$WORK/sign.log" 2>&1 \
  || { cat "$WORK/sign.log" >&2; fail "sign.sh --mode $MODE on the probe host failed"; }
check_ents "$HOST" "probe host ($MODE)"
# One bundle id ↔ one signing identity, forever (the container remembers the first).
REG="$HOME/Library/Caches/AntiChat-tests/signing-identities.tsv"
mkdir -p "$(dirname "$REG")"; touch "$REG"
: > "$OUT/identity.txt"
for b in "$HOST" "${SLOT_BUNDLES[@]/#/$HOST/Contents/XPCServices/}"; do
  [ "$b" = "$HOST" ] || b="$b.xpc"
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$b/Contents/Info.plist")
  case "$id" in "$PROBE_ID"*) ;; *) fail "probe bundle id $id does not carry $PROBE_ID" ;; esac
  case "$id" in "$SHIPPED_ID"|"$SHIPPED_ID".FileTools*|"$SHIPPED_ID".dev) fail "probe uses a shipped/dev bundle id: $id" ;; esac
  sig=$(codesign -dvv "$b" 2>&1 || true)  # read whole: an early-exiting reader would SIGPIPE codesign under pipefail
  who=$(awk -F= '/^Authority=/{print $2}' <<<"$sig" | sed -n 1p); who=${who:-adhoc}
  prev=$(awk -F'\t' -v id="$id" '$1==id {print $2; exit}' "$REG")
  [ -z "$prev" ] || [ "$prev" = "$who" ] || fail "$id was first signed by '$prev', now '$who': use another bundle id (macOS would ask the owner)"
  [ -n "$prev" ] || printf '%s\t%s\n' "$id" "$who" >> "$REG"
  echo "$id  $who" >> "$OUT/identity.txt"
  codesign --verify --strict "$b" || fail "$b signature broken"
done
export FT_SERVICE_PREFIX="$PROBE_ID"

# Runtime: the signed zip of catalog/runtimes.yaml, sha256-checked, into the Release Runtimes root.
ver=$(awk '/version:/ {gsub(/"/,"",$2); print $2; exit}' "$ROOT/catalog/runtimes.yaml")
sha=$(awk '/sha256:/ {print $2; exit}' "$ROOT/catalog/runtimes.yaml")
ZIP="$ROOT/build/runtimes/signed/filetools-runtime-$ver.zip"
RROOT="$HOME/Library/Application Support/AntiChat/Runtimes"
RT="$RROOT/filetools-runtime@$ver"
# A runtime the app already installed (it verified the catalog sha256 itself) is used as it is; the zip is only
# needed to put one there.
if [ ! -f "$RT/RUNTIME.json" ]; then
  [ -f "$ZIP" ] || fail "missing $ZIP (make runtime-filetools SIGN=1)"
  [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" = "$sha" ] || fail "$ZIP sha256 ≠ catalog"
fi
created=0
[ -d "$RROOT" ] || { mkdir -p "$RROOT"; created=1; }
cleanup() { if [ $created = 1 ]; then rm -rf "$RROOT"; fi; rm -rf "$WORK/host"; }
trap cleanup EXIT
if [ ! -f "$RT/RUNTIME.json" ]; then
  rm -rf "$RT.part"; mkdir -p "$RT.part"; ditto -x -k "$ZIP" "$RT.part"
  inner=$(find "$RT.part" -maxdepth 2 -name RUNTIME.json -print -quit); [ -n "$inner" ] || fail "zip has no RUNTIME.json"
  mv "$(dirname "$inner")" "$RT"; rm -rf "$RT.part"
fi
codesign --verify --strict "$RT/bin/ft-python" || fail "runtime launcher signature"

"$HOST/Contents/MacOS/AntiChat" "$RT" "$HOME" > "$OUT/probe.json" 2> "$WORK/probe.err" || { cat "$WORK/probe.err" >&2; fail "probe run failed"; }
if [ "$SUITE" -gt 0 ]; then
  mkdir -p "$SUITE_OUT"
  export FT_LOADAVG="$(sysctl -n vm.loadavg)"
  "$HOST/Contents/MacOS/AntiChat" "$RT" "$HOME" --suite "$ROOT/fixtures/sandbox/security" "$SUITE" > "$SUITE_OUT/suite.json" 2> "$WORK/suite.err" \
    || { cat "$WORK/suite.err" >&2; fail "AT-NFR-SEC3 suite failed (see ${SUITE_OUT#$ROOT/}/suite.json)"; }
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print('AT-NFR-SEC3 (%s): %d/%d, 05 peak %.3f x cap, 06 CPU p95 %.0f %%, bystander %.2f s' % (sys.argv[2], d['passed'], d['runs'], d['peak_ratio_05'], d['cpu_p95_06'], d['concurrent_answer_max_s']))" "$SUITE_OUT/suite.json" "$MODE"
fi

rc=0; FT_SLOTS="$SLOTS" python3 -I - "$OUT/probe.json" "$OUT/verdict.txt" <<'PY' || rc=$?
import json, os, sys
d = json.load(open(sys.argv[1])); bad = []
# A-M6-T18b closed (M6.T19): the App Sandbox base profile's home allowances (Keychains, Spelling, Fonts, Input
# Methods, Dictionaries) are removed by the temporary-exception.sbpl deny rules, so they are judged like every probe.
pong = d["pong"]
if not (pong["default"]["sandboxed"] and not pong["default"]["network"]): bad.append(f"default pong {pong['default']}")
if not (pong["net"]["sandboxed"] and pong["net"]["network"]): bad.append(f"net pong {pong['net']}")
# A-M6-T21a (a): every slot service answers, sandboxed, with its variant's network flag, in its own process.
slots = d.get("slots", {})
if len(slots) != 2 * int(os.environ["FT_SLOTS"]): bad.append(f"slot pongs {sorted(slots)}")
for sid, p in slots.items():
    if not (p["sandboxed"] and p["network"] == (".FileTools.Net." in sid)): bad.append(f"slot {sid} pong {p}")
if len({p["pid"] for p in slots.values()}) != len(slots): bad.append("two slots answered from one process")
for variant in ("default", "net"):
    for k, v in d[variant].items():
        if k.startswith("info "):
            continue                   # recorded, not judged
        path = k.split(" ", 2)[2] if k.startswith("read ") else k.split(" ", 1)[1]
        if k.startswith(("read ", "list ")) and v == "ENOENT" and not os.path.exists(path):
            ok = True                  # absent on this Mac: nothing to read (the sandbox answers the lookup)
        elif k.startswith("allowed "):
            ok = v == "ok"
        elif variant == "net" and k == "net c connect 127.0.0.1:1":
            ok = v == "ECONNREFUSED"   # network.client: the socket is permitted, nothing listens there
        elif k.endswith("dns example.com"):
            ok = v != "ok"             # name resolution needs mDNSResponder (a mach-lookup the sandbox refuses)
        elif k == "env":
            ok = False
        else:
            ok = v == "EPERM"
        if not ok:
            bad.append(f"{variant}: {k} = {v}")
n = sum(len(d[v]) for v in ("default", "net"))
text = f"probes {n}, failures {len(bad)}\n" + "".join(x + "\n" for x in bad)
open(sys.argv[2], "w").write(text); print(text, end="")
sys.exit(1 if bad else 0)
PY
[ $rc = 1 ] && fail "kernel boundary failures (see ${OUT#$ROOT/}/verdict.txt)"
echo "ft-release-probe: pass → ${OUT#$ROOT/}"
