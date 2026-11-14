#!/usr/bin/env bash
# M4.T11 (`make test-offline FILTER=SandboxedWebPreview`): the Debug app's artifacts host opens
# fixtures/web/preview/network-probe.html in the side panel's SandboxedWebPreview while running under the
# deny-outbound sandbox (tools/offline/run-offline.sh: exit 1 on any denial or IP socket of the app's processes).
# WebKit's network process is not a child of the app, so the authoritative zero-network check is the counting
# listener in SandboxedWebPreviewTests; this case adds the app-level view (no denials, no sockets).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fx="${ANTICHAT_FIXTURES:-$root/fixtures}"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cp "$fx/web/preview/network-probe.html" "$fx/web/preview/page.svg" "$dir/"
"$root/tools/offline/run-offline.sh" "${SECONDS_RUN:-15}" -- -ArtifactsHarness "$dir"
