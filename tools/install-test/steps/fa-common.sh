#!/bin/bash
# Shared by the in-VM final-acceptance steps (sourced; M10.T09). Runs as the VM's own user (admin), the clean account.
# The test-flavoured build of the RC commit (Debug: the probes and hooks exist only there) is /Applications/AntiChat.app;
# its container is ~/Library/Application Support/AntiChat-Dev and its defaults domain app.antichat.AntiChat.dev.
# Evidence goes to the share: $X/out/AT-FA-<nn>/ (the host moves it to build/at/AT-FA-<nn>/<date>/).
X="/Volumes/My Shared Files/xfer"
MIRROR="/Volumes/My Shared Files/mirror"
STEPS="$HOME/steps"
APP=/Applications/AntiChat.app
BIN="$APP/Contents/MacOS/AntiChat"
CONTAINER="$HOME/Library/Application Support/AntiChat-Dev"
DB="$CONTAINER/antichat.sqlite"
DOMAIN=app.antichat.AntiChat.dev
MIRROR_PORT=8770
export ANTICHAT_FIXTURES="$HOME/fixtures"

# fa_out <AT-FA-nn>: the leg's evidence folder (fresh), echoed.
fa_out() { local d="$X/out/$1"; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }

FA_FAILS=0
FA_CHECKS=""
# check "<label>" "<shell condition>"
check() {
    if eval "$2"; then echo "[ok]   $1"; FA_CHECKS+="ok	$1"$'\n'
    else echo "[FAIL] $1"; FA_CHECKS+="FAIL	$1"$'\n'; FA_FAILS=$((FA_FAILS + 1)); fi
}
# note "<label>": a sub-check that cannot run here (reason in the label); never counted as a pass.
note() { echo "[pending] $1"; FA_CHECKS+="pending	$1"$'\n'; }
# fa_result <out dir> <AT-FA-nn> <form>: result.json + checks.tsv; exit status = pass.
fa_result() {
    printf '%s' "$FA_CHECKS" > "$1/checks.tsv"
    local pending; pending=$(grep -c '^pending' "$1/checks.tsv" || true)
    python3 -I - "$1" "$2" "$3" "$FA_FAILS" "$pending" <<'PY'
import json, sys, datetime
out, at, form, fails, pending = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
rows = [l.split("\t", 1) for l in open(f"{out}/checks.tsv").read().splitlines() if l]
json.dump({"at": at, "form": form, "pass": fails == 0, "fails": fails, "pending_subchecks": pending,
           "checks": [{"status": s, "check": c} for s, c in rows],
           "finished": datetime.datetime.now(datetime.timezone.utc).isoformat()}, open(f"{out}/result.json", "w"), indent=1)
PY
    echo "$2: $([ "$FA_FAILS" = 0 ] && echo PASS || echo "FAIL ($FA_FAILS)")"
    [ "$FA_FAILS" = 0 ]
}

# json <file> <python expression on `j`>: prints the value ('' when missing).
json() { python3 -I -c 'import json,sys
try: j=json.load(open(sys.argv[1]))
except Exception: j={}
try: v=eval(sys.argv[2])
except Exception: v=""
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))' "$1" "$2"; }

sql() { sqlite3 -readonly "$DB" "$1"; }

# app_quit: SIGTERM (an Apple event would wait on an Automation consent nobody answers), then SIGKILL after 20 s.
app_quit() {
    pkill -TERM -f "$BIN" 2>/dev/null || true
    for _ in $(seq 1 40); do pgrep -f "$BIN" >/dev/null || return 0; sleep 0.5; done
    pkill -KILL -f "$BIN" 2>/dev/null || true
}

# probe <dir> <leg> [timeout s] [extra app args…]: one -FinalAcceptanceProbe launch in the GUI session (background,
# never activating), waited for. The app's stderr → <dir>/app.log.
probe() {
    local dir="$1" leg="$2" t="${3:-1800}"; shift 3 || shift $#
    mkdir -p "$dir"; rm -f "$dir/probe.json"; printf '%s\n' "$leg" > "$dir/leg"
    open -g -n "$APP" --stderr "$dir/app.log" --args -ApplePersistenceIgnoreState YES -FinalAcceptanceProbe "$dir" "$@"
    local i gone=0
    for i in $(seq 1 "$t"); do
        if ! pgrep -f "$BIN" >/dev/null; then
            [ -f "$dir/probe.json" ] && return 0
            gone=$((gone + 1)); [ $gone -ge 10 ] && { echo "probe $leg: the app exited without probe.json (crash?)"; tail -5 "$dir/app.log"; return 1; }
        fi
        sleep 1
    done
    echo "probe $leg: timed out after ${t}s"; app_quit; return 1
}

# The local mirror of the catalog's Hugging Face files (fa-mirror.py), served by range-server.py --literal as a
# child of the calling step (it exits with it). The app reaches it through DEBUG -DownloadHost.
mirror_up() {
    python3 -I "$STEPS/range-server.py" --root "$MIRROR" --literal --port "$MIRROR_PORT" --log "$1/mirror.log" \
        > "$1/mirror.out" 2>&1 &
    MIRROR_PID=$!
    for _ in $(seq 1 50); do grep -q '^PORT' "$1/mirror.out" 2>/dev/null && return 0; sleep 0.2; done
    echo "mirror did not start"; return 1
}
mirror_down() { [ -n "${MIRROR_PID:-}" ] && kill "$MIRROR_PID" 2>/dev/null; MIRROR_PID=""; }

# collect_logs <out dir>: the app's and helper's logs + the last 20 min of the unified log for the helper, llama-server
# and memory pressure (jetsam) — the evidence when a leg fails inside the VM.
collect_logs() {
    mkdir -p "$1/logs"
    cp -R "$HOME/Library/Logs/AntiChat-Dev/." "$1/logs/" 2>/dev/null || true
    # Crash reports of the app, the helper and llama-server (ReportCrash writes them a few seconds after the crash).
    mkdir -p "$1/logs/crash"
    find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 2 \
        \( -iname '*AntiChat*' -o -iname '*llama*' \) -mmin -30 -exec cp {} "$1/logs/crash/" \; 2>/dev/null || true
    # AT-FA-05 lesson: the helper's own lines plus how it ended (launchd's exit reason, ReportCrash, kernel kills).
    log show --last 20m --style compact --info \
        --predicate 'subsystem == "app.antichat" OR process == "AntiChatEngine" OR process == "llama-server" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "memorystatus" OR (eventMessage CONTAINS[c] "AntiChat" AND (process == "launchd" OR process == "ReportCrash" OR process == "kernel" OR process == "runningboardd" OR process == "xpcproxy"))' \
        2>/dev/null | grep -v -E 'CoreVideo|MMapped' | tail -3000 > "$1/logs/unified.log" || true
}

# Peak phys_footprint (bytes) of the helper and its children while <pid> runs → <file> (NFR-R1 at this VM's tier).
footprint_sampler() {
    local file="$1" watch="$2"
    ( peak=0
      while kill -0 "$watch" 2>/dev/null || pgrep -f "$BIN" >/dev/null; do
          total=0
          for p in $(pgrep -f 'AntiChatEngine|llama-server|sd-server'); do
              b=$(footprint -p "$p" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3; m=(u ~ /GB/)?1073741824:(u ~ /MB/)?1048576:(u ~ /KB/)?1024:1; printf "%d", v*m; exit}')
              total=$((total + ${b:-0}))
          done
          [ "$total" -gt "$peak" ] && peak=$total && echo "$peak" > "$file"
          sleep 1
      done ) &
    SAMPLER_PID=$!
}
