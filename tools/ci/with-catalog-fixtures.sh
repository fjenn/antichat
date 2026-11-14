#!/usr/bin/env bash
# with-catalog-fixtures.sh <command…> (Q-015 r4, AT-294 UI leg): serves each signed fixture catalog
# fixtures/catalog/<name>.json (+ .sig) as http://127.0.0.1:<port>/<name>/catalog.json on a free port and passes the port to
# the UI test runner as TEST_RUNNER_ANTICHAT_CATALOG_PORT (UpdateAskUITests). The sandboxed runner cannot serve it itself.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir=$(mktemp -d "${TMPDIR:-/tmp}/antichat-catalogs.XXXXXX")
for f in "$root"/fixtures/catalog/*.json; do
  [ -f "$f.sig" ] || continue
  n=$(basename "$f" .json)
  mkdir -p "$dir/$n"
  ln -s "$f" "$dir/$n/catalog.json"
  ln -s "$f.sig" "$dir/$n/catalog.json.sig"
done
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -rf "$dir"' EXIT
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export TEST_RUNNER_ANTICHAT_CATALOG_PORT="$port"
# Q-015 r5, AT-294 precondition (vq-10 § Updates): an update offer needs an INSTALLED slot to upgrade. A fresh (or the
# default dev) container has no `model_install` row, so UpdatePolicy found no candidate and no offer row showed. Seed
# one container per upgrade catalog (a catalog cached by one test would be a rollback for the other) with the Chat
# starter chat-0.8b in chat/normal/chat_fast, APFS-cloned from the dev models cache (`make models-dev`; no network).
# UpdateAskUITests launch with `-ANTICHAT_DEV_CONTAINER $ANTICHAT_UPDATE_CONTAINERS/<catalog>`.
devmodels="${ANTICHAT_DEV_MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
if [ -d "$devmodels/chat-0.8b" ] && [ -f "$root/fixtures/catalog/catalog-valid.json" ]; then
  cli="$(cd "$root" && swift build --product antichat-cli --show-bin-path 2>/dev/null)/antichat-cli"
  [ -x "$cli" ] || (cd "$root" && swift build --product antichat-cli -q >/dev/null 2>&1)
  if [ -x "$cli" ]; then
    for c in catalog-upgrade catalog-upgrade-big; do
      ct="$dir/containers/$c"
      mkdir -p "$ct"
      "$cli" models import --models "$ct/Models" --db "$ct/antichat.sqlite" --from "$devmodels" --id chat-0.8b \
        --slot chat/normal/chat_fast --catalog "$root/fixtures/catalog/catalog-valid.json" >/dev/null 2>&1 \
        || echo "with-catalog-fixtures: could not seed $c (chat-0.8b import failed)" >&2
    done
    export TEST_RUNNER_ANTICHAT_UPDATE_CONTAINERS="$dir/containers"
  fi
fi
"$@"
