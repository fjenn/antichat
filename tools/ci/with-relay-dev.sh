#!/usr/bin/env bash
# with-relay-dev.sh <command…> (Q-015 r6, AT-255 c3/c5-app UI leg): runs <command> with two `make relay-dev` relays
# (RELAY_DEV_LOCAL=1: the no-login adapter with relay/.env.test = mock Composio on loopback) on free 127.0.0.1 ports,
# and passes them to the UI test runner as TEST_RUNNER_ANTICHAT_RELAY_URL and TEST_RUNNER_ANTICHAT_RELAY_URL_LIMITED
# (the second runs with RELAY_TEST_MCP_PER_MIN=1: ComposioUITests.testRateLimitedShowsCopy). The runner is sandboxed
# and cannot listen itself. Each relay runs in its own process group (make → npx → tsx → node), ended by the EXIT trap.
# A relay/.env.local (real Composio) would win over .env.test: the relays are not started then.
# Without node, or when a relay does not come up, the command runs anyway (ComposioUITests then fail, as before).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -x /opt/homebrew/bin/node ] && export PATH="/opt/homebrew/bin:$PATH"
command -v node >/dev/null || exec "$@"
if [ -e "$root/relay/.env.local" ]; then echo "with-relay-dev: relay/.env.local present, not starting a mock relay" >&2; exec "$@"; fi
log="$root/build/relay-dev"
mkdir -p "$log"
groups=()
cleanup() { for g in "${groups[@]}"; do pkill -TERM -g "$g" 2>/dev/null; done; }
trap cleanup EXIT
set -m  # background jobs get their own process group (pgid = the job's pid)

# start <name> [VAR=value…]: sets $started to the relay's URL, or empty.
start() {
  local name=$1; shift
  local p m pid
  read -r p m < <(python3 -I -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
  env RELAY_DEV_LOCAL=1 PORT="$p" RELAY_MOCK_PORT="$m" "$@" make -C "$root" relay-dev >"$log/$name.log" 2>&1 &
  pid=$!
  groups+=("$pid")
  started=""
  # A fresh worktree runs `npm ci` first; the server itself is up in ~2 s.
  for _ in $(seq 1 1800); do
    if curl -fs "http://127.0.0.1:$p/v1/health" >/dev/null 2>&1; then started="http://127.0.0.1:$p"; return; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  echo "with-relay-dev: relay $name did not start (log $log/$name.log)" >&2
}

start relay
[ -n "$started" ] && export TEST_RUNNER_ANTICHAT_RELAY_URL="$started"
start relay-limited RELAY_TEST_MCP_PER_MIN=1
[ -n "$started" ] && export TEST_RUNNER_ANTICHAT_RELAY_URL_LIMITED="$started"
set +m
"$@"
