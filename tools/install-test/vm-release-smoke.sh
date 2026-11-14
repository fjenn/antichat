#!/bin/bash
# tools/install-test/vm-release-smoke.sh — the clean-Mac release journey in a fresh Tart VM (M10.T09 release pass of
# the final acceptance: AT-FA-01, -12, -13 Release half; checklist items 3, 12, 13; R-225, R-219, R-226 way 2). One VM
# clone runs the whole journey, then is deleted (the base image stays):
#   1. (AT-FA-01) download N-1 the way a user does: the DMG is served by tools/release/feed-server.py INSIDE the VM on
#      127.0.0.1 (the website's download link resolves to the GitHub Release once the public repo exists, M10 owner
#      steps §3) and fetched over HTTP, then given the quarantine attribute a browser writes → Gatekeeper
#      (`spctl -t open`, primary signature) → mount → ditto to /Applications → `spctl -t exec` → first open;
#        FORM=devid (notarized): Gatekeeper accepts "Notarized Developer ID"; the first open is held behind the
#          standard "downloaded from the Internet" question (translocated, CoreServicesUIAgent);
#        FORM=dev (dev/adhoc, UNNOTARIZED or DEVKEYS-dev): Gatekeeper rejects; the first open is held behind macOS's
#          "Apple could not verify…" dialog; System Settings › Open Anyway is a click (Q-015) — its effect, the
#          approval that lifts the quarantine block, is applied by removing the quarantine attribute;
#      then: alive after 20 s, no dyld/code-signing errors, an on-screen window, the container, `codesign --verify`;
#   2. (AT-FA-12) SEED_DB (optional): user data from one schema version back (fixtures/chats/db/v<N>_*.sqlite, 20
#      chats with branches) replaces the first run's database; N-1 launches → migrates → a pre-migration backup;
#      canonical dump (db-canon.py) + Models listing before the update;
#   3. (AT-FA-12) upgrade through the local dev appcast: N + a signed test feed (no phased rollout) are served by
#      feed-server.py inside the VM; the dev-keys build is pointed at it (AntiChatFeedURLOverride), the last check is
#      back-dated, relaunch → Sparkle fetches the feed, downloads N, verifies its EdDSA signature; a normal quit
#      installs it (SUAutomaticallyUpdate) → /Applications holds N's CFBundleVersion, N launches, the data and the
#      models are unchanged; the server's request log goes through pr5-check.py (NFR-PR5);
#   4. (AT-FA-13, Release) uninstall the documented manual way (Help › How to Uninstall, way 2: Trash + the listed
#      folders) → zero-files. The in-app sheet needs UI automation (Q-015); its action runs in the debug pass.
# A fresh VM is its own machine: launching the shipped bundle id under this signature there is fine.
# Usage: FORM=dev|devid PREV_DMG=<N-1 dmg> DMG=<N dmg> [SEED_DB=<sqlite>] [OUT=<dir>] vm-release-smoke.sh
# Evidence: $OUT (default build/at/AT-FA/<date>/release): journey.log + per-step files; every check line is tagged
# with its AT-FA id. Exit 3 = not run here (tart / image missing).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"; cd "$root"
prev="${PREV_DMG:?PREV_DMG=the N-1 DMG}"; new="${DMG:?DMG=the N DMG}"; form="${FORM:-devid}"; seed="${SEED_DB:-}"
source "$root/tools/install-test/lib/vm.sh"
vm_init || exit 3
out="${OUT:-$root/build/at/AT-FA/$(date +%Y%m%d-%H%M%S)/release}"; mkdir -p "$out"
log="$out/journey.log"; exec > >(tee -a "$log") 2>&1
xfer="$out/xfer"; mkdir -p "$xfer/dl"; cp "$prev" "$new" "$xfer/"; cp "$prev" "$xfer/dl/"
cp tools/release/feed-server.py tools/ci/db-canon.py tools/ci/zero-files.sh tools/ci/antichat-paths.txt "$xfer/"
[ -n "$seed" ] && cp "$seed" "$xfer/seed.sqlite"
pdmg="$(basename "$prev")"; ndmg="$(basename "$new")"
echo "form $form; N-1 $pdmg; N $ndmg; seed ${seed:-none}"
step() { echo; echo "== $(date +%T) $*"; }
fail=0; check() { if eval "$2"; then echo "[ok]   $1"; else echo "[FAIL] $1"; fail=$((fail + 1)); fi; }

fs=""
cleanup() {
    vm_cleanup   # the clone goes; the base image stays
    # Keep only text evidence: the request log moves out of the share, the DMG copies and served files go.
    [[ -f "$xfer/requests.log" ]] && { rm -f "$out/requests.log"; mv "$xfer/requests.log" "$out/requests.log"; }
    rm -rf "$xfer"
}
trap cleanup EXIT
step "clone $VM_IMAGE, boot headless"
vm_clone "ac-release-$(date +%s)" 8192 4
vm_boot "$out/tart-run.log" "$xfer"
vx "sw_vers; whoami; uname -m"
X="$VM_SHARE"
# The Cirrus base image ships with Gatekeeper's assessments disabled ("override=security disabled"): turn them on, as
# on every user's Mac, or every spctl answer below would be "accepted" regardless of the signature.
vx "sudo spctl --global-enable 2>&1 || sudo spctl --master-enable 2>&1; spctl --status" > "$out/gatekeeper-status.txt" 2>&1 || true
check "AT-FA-01: Gatekeeper assessments enabled in the VM ($(tr -d '\r' < "$out/gatekeeper-status.txt" | tail -1))" "grep -q 'assessments enabled' '$out/gatekeeper-status.txt'"

# JXA helpers inside the VM (no TCC: CGWindowList owner names and NSRunningApplication need no consent).
vx "cat > /tmp/ac.js <<'JS'
ObjC.import('AppKit'); ObjC.import('CoreGraphics');
function run(argv) {
  if (argv[0] === 'windows') {
    var l = ObjC.deepUnwrap(ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly, 0))) || [];
    return l.filter(function (w) { return w.kCGWindowOwnerName === 'AntiChat' && w.kCGWindowLayer === 0; }).length;
  }
  if (argv[0] === 'quit') {
    var a = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('app.antichat.AntiChat');
    for (var i = 0; i < a.count; i++) a.objectAtIndex(i).terminate;
    return a.count;
  }
}
JS"
container='$HOME/Library/Application Support/AntiChat'

install_dmg() {  # install_dmg <dmg basename>: download (local host) + quarantine, Gatekeeper, copy to /Applications
    vx "rm -rf /Applications/AntiChat.app ~/Downloads/$1
        nohup python3 -I '$X/feed-server.py' --root '$X/dl' --bind 127.0.0.1 --port 8766 --log /tmp/dl.log > /tmp/dl.txt 2>&1 &
        for i in \$(seq 40); do curl -s -o /dev/null http://127.0.0.1:8766/ && break; sleep 0.5; done; cat /tmp/dl.txt
        curl -sS -f -o ~/Downloads/$1 http://127.0.0.1:8766/$1 -w 'downloaded %{size_download} bytes at %{speed_download} B/s\n'
        pkill -f 'feed-server.py --root $X/dl' || true
        xattr -w com.apple.quarantine \"0083;\$(printf %x \$(date +%s));Safari;\" ~/Downloads/$1; xattr -p com.apple.quarantine ~/Downloads/$1" > "$out/download.txt" 2>&1 || true
    check "AT-FA-01: $1 downloaded and quarantined like a browser download" "grep -q '^downloaded' '$out/download.txt' && grep -q Safari '$out/download.txt'"
    vx "spctl -a -vvv -t open --context context:primary-signature ~/Downloads/$1" > "$out/gk-dmg-$1.txt" 2>&1 || true
    if [ "$form" = devid ]; then
        check "AT-FA-01: Gatekeeper accepts the downloaded $1 (Notarized Developer ID)" "grep -q 'source=Notarized Developer ID' '$out/gk-dmg-$1.txt'"
    else
        check "AT-FA-01: Gatekeeper does not accept the unnotarized $1 (dev form: expected)" "grep -q -E 'rejected|no usable signature' '$out/gk-dmg-$1.txt'"
    fi
    vx "hdiutil attach -nobrowse -readonly ~/Downloads/$1 -mountpoint /tmp/acdmg >/dev/null && ditto /tmp/acdmg/AntiChat.app /Applications/AntiChat.app && hdiutil detach /tmp/acdmg >/dev/null"
    vx "spctl -a -vvv -t exec /Applications/AntiChat.app" > "$out/gk-app-$1.txt" 2>&1 || true
    if [ "$form" = devid ]; then
        check "AT-FA-01: Gatekeeper accepts /Applications/AntiChat.app from $1" "grep -q 'source=Notarized Developer ID' '$out/gk-app-$1.txt'"
    else
        check "AT-FA-01: Gatekeeper rejects the unnotarized app (dev form: expected)" "grep -q 'rejected' '$out/gk-app-$1.txt'"
    fi
    vx "xattr -p com.apple.quarantine /Applications/AntiChat.app" > "$out/quarantine-app.txt" 2>&1 || true
    check "AT-FA-01: the copied app carries the quarantine (first open is assessed)" "grep -q Safari '$out/quarantine-app.txt'"
}
first_open() {  # the quarantined app's first launch: macOS holds it behind its first-open dialog
    vx "(open -g -a /Applications/AntiChat.app >/dev/null 2>&1 &)"; sleep 10
    vx "ps -axo stat=,command= | grep -E 'AntiChat.app/' | grep -v grep; pgrep -lx CoreServicesUIAgent" > "$out/first-open.txt" 2>&1 || true
    local what="the standard 'downloaded from the Internet' question"; [ "$form" = devid ] || what="the 'Apple could not verify' dialog"
    check "AT-FA-01: first open is held by Gatekeeper behind $what (app translocated, not running; CoreServicesUIAgent up)" \
        "grep -q -E '^T.*AppTranslocation/.*/AntiChat.app/' '$out/first-open.txt' && grep -q CoreServicesUIA '$out/first-open.txt'"
    # [Open] (devid) / System Settings › Open Anyway (dev): Gatekeeper records the approval; the quarantine no longer
    # blocks the app. The click itself needs UI automation (Q-015); its effect is applied here.
    vx "pkill -9 -f 'AppTranslocation/.*/AntiChat.app' || true; pkill -f 'open -g -a /Applications/AntiChat.app' || true
        xattr -dr com.apple.quarantine /Applications/AntiChat.app"
}
launch_check() {  # launch_check <label> <AT tag>
    vx "(open -g -a /Applications/AntiChat.app >/dev/null 2>&1 &)"; sleep 20
    check "$2: $1: AntiChat running after 20 s" "vx 'pgrep -x AntiChat' >/dev/null"
    vx "log show --last 3m --predicate 'process == \"AntiChat\" OR eventMessage CONTAINS \"AntiChat\"' 2>/dev/null | grep -E -i 'Library not loaded|code signature invalid|CODESIGNING|Termination Reason' || true" > "$out/log-$1.txt"
    check "$2: $1: no dyld / code-signing errors in the unified log" "[ ! -s '$out/log-$1.txt' ]"
    check "$2: $1: AntiChat shows a window" "[ \"\$(vx 'osascript -l JavaScript /tmp/ac.js windows' | tr -d '\r')\" -ge 1 ]"
}
quit_app() { vx "osascript -l JavaScript /tmp/ac.js quit >/dev/null; for i in \$(seq 30); do pgrep -x AntiChat >/dev/null || break; sleep 1; done"; }
version() { vx "defaults read /Applications/AntiChat.app/Contents/Info CFBundleVersion" | tr -d '\r'; }
dump() {  # dump <tag>: canonical database dump + the Models listing (app quit: the WAL is checkpointed)
    vx "python3 -I '$X/db-canon.py' \"$container/antichat.sqlite\" --out /tmp/db-$1.json 2>/dev/null; cat /tmp/db-$1.json" > "$out/db-$1.json" || true
    vx "cd \"$container\" && find Models -type f -o -type l 2>/dev/null | sort" > "$out/models-$1.txt" || true
}

step "1 AT-FA-01: download N-1 ($pdmg), Gatekeeper, first open"
install_dmg "$pdmg"; v1="$(version)"; echo "installed CFBundleVersion $v1"
first_open
launch_check first-run AT-FA-01
check "AT-FA-01: first run created the container" "vx 'test -d \"$container\"'"
vx "codesign --verify --deep --strict --verbose=2 /Applications/AntiChat.app" > "$out/codesign-verify.txt" 2>&1 && cs=0 || cs=$?
check "AT-FA-01: codesign --verify --deep --strict passes" "[ $cs = 0 ]"
vx "ls -la \"$container\"" > "$out/container-before.txt" 2>&1 || true

if [ -n "$seed" ]; then
    step "2 AT-FA-12: user data from the previous schema ($(basename "$seed")) → N-1 migrates"
    quit_app
    vx "cd \"$container\" && rm -f antichat.sqlite-wal antichat.sqlite-shm && cp '$X/seed.sqlite' antichat.sqlite"
    launch_check seeded AT-FA-12
    quit_app
    vx "ls -la \"$container/Backups\"" > "$out/backups.txt" 2>&1 || true
    check "AT-FA-12: the migration kept a pre-migration backup (Backups/pre-*.sqlite)" "grep -q 'pre-' '$out/backups.txt'"
    dump before
    check "AT-FA-12: the migrated data holds the seeded chats" "python3 -I -c 'import json,sys; d=json.load(open(\"$out/db-before.json\")); t=d.get(\"tables\", d); sys.exit(0 if len(t.get(\"chat\", [])) > 0 else 1)'"
fi

step "3 AT-FA-12: upgrade N-1 → N through the local dev appcast"
serve="$xfer/serve"; mkdir -p "$serve"
# An isolated test feed: N-1 + N only (generate_appcast also makes the N-1 → N delta), nothing from build/updates.
mkdir -p "$xfer/dmgs" "$xfer/updates"; cp "$prev" "$new" "$xfer/dmgs/"
DMG_DIR="$xfer/dmgs" UPDATES_DIR="$xfer/updates" OUT="$serve" NO_PHASED=1 FEED=dev DEV_BASE_URL="http://127.0.0.1:8765" \
    tools/release/appcast.sh > "$out/appcast.txt" 2>&1 || { cat "$out/appcast.txt"; exit 1; }
mv "$serve/appcast-dev.xml" "$serve/appcast-test.xml"; cp "$new" "$serve/"
cp "$xfer/updates"/*.delta "$serve/" 2>/dev/null || true   # generate_appcast's deltas, referenced by the feed
cp "$serve/appcast-test.xml" "$out/appcast-test.xml"
vx "nohup python3 -I '$X/feed-server.py' --root '$X/serve' --bind 127.0.0.1 --port 8765 --log '$X/requests.log' > /tmp/feed-server.txt 2>&1 &"
vx "for i in \$(seq 40); do curl -s -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.5; done"; ln -sf "$xfer/requests.log" "$out/requests.log"
quit_app
vx "defaults write app.antichat.AntiChat AntiChatFeedURLOverride http://127.0.0.1:8765/appcast-test.xml
    defaults write app.antichat.AntiChat SULastCheckTime -date '2020-01-01 00:00:00 +0000'"
vx "(open -g -a /Applications/AntiChat.app >/dev/null 2>&1 &)"
for i in $(seq 90); do grep -q -E "$ndmg|\.delta" "$out/requests.log" 2>/dev/null && break; sleep 5; done
check "AT-FA-12: Sparkle fetched the signed feed" "grep -q 'appcast-test.xml' '$out/requests.log'"
check "AT-FA-12: Sparkle downloaded the update (delta or $ndmg)" "grep -q -E '$ndmg|\.delta' '$out/requests.log'"
sleep 60   # download + EdDSA check + extraction into Sparkle's staging area
quit_app
for i in $(seq 60); do [[ "$(version)" != "$v1" ]] && break; sleep 5; done
v2="$(version)"; echo "after quit: CFBundleVersion $v2 (was $v1)"
check "AT-FA-12: update installed on quit (CFBundleVersion $v1 → $v2)" "[ '$v2' != '$v1' ]"
vx "log show --last 10m --predicate 'process CONTAINS \"Sparkle\" OR process CONTAINS \"Autoupdate\" OR process == \"AntiChat\"' 2>/dev/null | grep -i -E 'sparkle|update' | tail -40" > "$out/sparkle-log.txt" || true
launch_check upgraded AT-FA-12
check "AT-FA-12: the container survived the update" "vx 'test -d \"$container\"'"
vx "ls -la \"$container\"" > "$out/container-after.txt" 2>&1 || true
if [ -n "$seed" ]; then
    quit_app
    dump after
    check "AT-FA-12: user data unchanged by the update (canonical dump equal)" "[ -s '$out/db-after.json' ] && cmp -s '$out/db-before.json' '$out/db-after.json'"
    check "AT-FA-12: models unchanged by the update" "cmp -s '$out/models-before.txt' '$out/models-after.txt'"
fi
vx "pkill -f feed-server.py || true"
python3 -I tools/release/pr5-check.py "$out/requests.log" --feed-path /appcast-test.xml > "$out/pr5.txt" 2>&1 || true
check "AT-FA-12: NFR-PR5: the update check carries no identifier" "grep -q 'pr5-check: pass' '$out/pr5.txt'"

step "4 AT-FA-13 (Release): uninstall the documented way (Help › How to Uninstall, way 2) → zero files"
# Exactly the documented list (antichat-paths.txt = DataPaths = the uninstall page): Trash the app, delete each path.
vx "osascript -l JavaScript /tmp/ac.js quit >/dev/null; sleep 5; pkill -x AntiChat || true
    mv /Applications/AntiChat.app ~/.Trash/
    while IFS= read -r line; do
      case \"\$line\" in ''|'#'*|'<'*) continue ;; esac
      p=\"\${line/#\\~/\$HOME}\"; p=\"\${p/\\\$TMPDIR/\${TMPDIR%/}}\"
      for f in \${~p}(N); do rm -rf \"\$f\"; done
    done < '$X/antichat-paths.txt'
    defaults delete app.antichat.AntiChat 2>/dev/null || true"
vx "bash '$X/zero-files.sh' --paths '$X/antichat-paths.txt' --bundle-id app.antichat.AntiChat" > "$out/zero-files.txt" 2>&1 \
    && zero=0 || zero=$?
check "AT-FA-13: zero files left after the documented uninstall" "[ $zero = 0 ]"
# The list above is what the uninstall page documents; sweep for anything it misses (new folders, e.g. Sparkle's).
vx "find \"\$HOME/Library\" -maxdepth 4 \\( -iname '*antichat*' -o -iname 'app.antichat.*' \\) -not -path '*/.Trash/*' 2>/dev/null" > "$out/sweep.txt" || true
check "AT-FA-13: no undocumented AntiChat files left in ~/Library" "[ ! -s '$out/sweep.txt' ]"

step "result"
echo "vm-release-smoke [$form]: $([[ $fail == 0 ]] && echo PASS || echo "$fail failure(s)") → $out"
((fail == 0))
