#!/usr/bin/env bash
# with-mcp-ref.sh <command…> (Q-015 r4, AT-257 UI leg): runs <command> with the reference OAuth AS + protected MCP
# server (tools/mcp-ref/mcp.ts --no-cimd) listening on two free 127.0.0.1 ports, and passes its endpoint to the UI test
# runner as TEST_RUNNER_ANTICHAT_MCP_REF_URL (MCPOAuthUITests). The runner is sandboxed and cannot listen itself.
# Without node the command runs anyway and MCPOAuthUITests skips (Q-007).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node=$(command -v node || true)
[ -x /opt/homebrew/bin/node ] && node=/opt/homebrew/bin/node
if [ -z "$node" ]; then exec "$@"; fi
pid=""
for _ in 1 2 3; do
  read -r p q < <(python3 -I -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
  NODE_NO_WARNINGS=1 "$node" "$root/tools/mcp-ref/mcp.ts" --port "$p" --as-port "$q" --no-cimd >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    if curl -fs "http://127.0.0.1:$p/.well-known/oauth-protected-resource/mcp" >/dev/null 2>&1 \
      && curl -fs "http://127.0.0.1:$q/.well-known/oauth-authorization-server" >/dev/null 2>&1; then break 2; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null; pid=""
done
if [ -z "$pid" ]; then echo "with-mcp-ref: the reference server did not start" >&2; exec "$@"; fi
trap 'kill "$pid" 2>/dev/null' EXIT
export TEST_RUNNER_ANTICHAT_MCP_REF_URL="http://127.0.0.1:$p/mcp"
# Q-015 r5: the web-auth alert ("… wants to use … to Sign In") belongs to the authentication agent, which the sandboxed
# runner cannot reach; tools/ci/webauth-continue.swift presses its Continue from outside (Accessibility grant needed).
wac="$root/build/webauth-continue"
if [ ! -x "$wac" ] || [ "$root/tools/ci/webauth-continue.swift" -nt "$wac" ]; then
  # r6: a failed compile is reported (r5 hid it), and the watcher logs what it sees to build/webauth-continue.log.
  mkdir -p "$root/build" && swiftc -O -o "$wac" "$root/tools/ci/webauth-continue.swift" 2>"$root/build/webauth-continue.build.log" \
    || { rm -f "$wac"; echo "with-mcp-ref: webauth-continue did not compile (build/webauth-continue.build.log)" >&2; }
fi
wpid=""
if [ -x "$wac" ]; then "$wac" 7200 "$root/build/webauth-continue.log" & wpid=$!; fi
# M9.T03: the accessibility audit tests' exact element-less count needs the app's focused element and its search
# fields' clear buttons, which only the Accessibility API outside the runner can read (tools/ci/a11y-axstate.swift).
axs="$root/build/a11y-axstate"
if [ ! -x "$axs" ] || [ "$root/tools/ci/a11y-axstate.swift" -nt "$axs" ]; then
  mkdir -p "$root/build" && swiftc -O -o "$axs" "$root/tools/ci/a11y-axstate.swift" 2>/dev/null || rm -f "$axs"
fi
apid=""
if [ -x "$axs" ]; then "$axs" 7200 & apid=$!; fi
trap 'kill "$pid" 2>/dev/null; [ -n "$wpid" ] && kill "$wpid" 2>/dev/null; [ -n "$apid" ] && kill "$apid" 2>/dev/null' EXIT
"$@"
