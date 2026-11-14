#!/usr/bin/env bash
# `make audit` (docs/prd/M1.md M1.T02; architecture §11; test-strategy §9). Runs every audit, never stops at the
# first failure, prints one summary line per check and exits 1 if any failed. Required check in ci.yml.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
py=python3
fail=0
summary=()
run() {
  local name=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed "s/^/[$name] /"
  if [[ $rc -eq 0 ]]; then summary+=("ok    $name"); else summary+=("FAIL  $name (exit $rc)"); fail=1; fi
}
ack_args=(--out build/audit/ACKNOWLEDGMENTS.md --json build/audit/acknowledgments.json)
# Licence scan: always offline (M4). Model licences come from catalog/models.yaml + the dev records, ported/design
# licences from tools/licences/github-records.json, SwiftPM pins from .build/checkouts, submodules from BINARIES_SRC; a
# build/acknowledgments/cache.json is only a fallback for an unrecorded component.
ack_args+=(--offline)
# A worktree has no Binaries submodule checkout: `BINARIES_SRC=<main checkout>/Binaries make audit`.
[[ -n "${BINARIES_SRC:-}" ]] && ack_args+=(--binaries-src "$BINARIES_SRC")
mkdir -p build/audit

run import-graph     $py -I tools/ci/import-graph.py
run r241-audit       $py -I tools/ci/r241-audit.py --full   # M7.T15: AT-241 c1 report build/at/AT-241/audit.json
run fixture-audit    $py -I tools/ci/fixture-audit.py
run child-safety-ci  $py -I tools/ci/check-workflows.py --job child-safety --paths "Packages/ChildSafetyCheck/**,catalog/models.yaml"
run forbidden-deps   $py -I tools/ci/forbidden-deps.py
run patch-lint       $py -I tools/ci/patch-lint.py
run vendored-allow   $py -I tools/ci/vendored-allowlist.py
run copy-sync        $py -I tools/ci/copy-sync.py
run url-session-lint $py -I tools/ci/url-session-lint.py
run no-raw-process  $py -I tools/ci/no-raw-process.py           # M7.T13 (D-026): spawns only via ProcessLauncher (R-265)
run no-bg-session    tools/ci/no-background-session.sh          # M2.T02: no background URLSession (gate contract)
run no-focus-steal   tools/ci/no-focus-steal.sh               # tests/probes never activate or post global input (BackgroundRun)
run design-gen       $py -I tools/design/gen-tokens.py --check
run design-copy      $py -I tools/design/gen-xcstrings.py --check
run a11y-lint        $py -I tools/ci/a11y-lint.py               # M9.T01: labels, VoiceOver-reachable taps, identifier ratchet
run keyboard-paths   $py -I tools/a11y/gen-keyboard-paths.py --check  # M9.T01: every function + settings row has a keyboard path
run l10n-source      $py -I tools/l10n/l10n-check.py --source en  # M9.T04: catalog fresh, no hard-coded UI literals
run l10n-langs       $py -I tools/l10n/l10n-check.py --langs de,fr,es,nl,pt --report-only  # counts; strict = AT-102
run filetools-ents  $py -I tools/release/gen-filetools-entitlements.py --check  # M6.T19: sandbox entitlements = generator (A-M6-T18b)
run tryout-guard     $py -I tools/ci/tryout-guard.py          # the owner try-out preview never reaches a release build
run devfeed-guard    $py -I tools/ci/devfeed-guard.py         # RC review P2-8: the Sparkle test key + feed override never reach a devid build
run perfharness-guard $py -I tools/ci/perfharness-guard.py    # M9.T05: the perf-harness build flag never reaches a release build
run signing-ids     $py -I tools/ci/signing-identity-ids.py   # M6.T19: one bundle id per signing identity (no consent dialogs)
run perf-targets     $py -I tools/perf/gen-targets.py --check   # M1.T26a: nfr_targets.json still matches nfr.md
run settings-map     $py -I tools/ci/settings-map-check.py      # M1.T22: Keys.swift defaults/sections vs settings-map
run no-retyped-budgets $py -I tools/ci/no-retyped-budgets.py  # M7.T14: tier budgets only in tier-budgets.json (A-M7-04)
run memory-writes    $py -I tools/ci/memory-write-paths.py      # M8.T02: memory written only by the tool or the user
run endpoints       $py -I tools/ci/endpoints-check.py         # M8.T09 fix: placeholder endpoints never reach a release user
run release-lint   $py -I tools/ci/release-lint.py            # M10.T01: no --deep signing, entitlement matrix, notary creds only via keychain profile
run pinned-keys    $py -I tools/release/gen-keys-swift.py --check   # M10.T04: PinnedKeys.swift generated from Config/Keys.*.plist
run hosting        $py -I tools/release/set-hosting.py --check     # M10.T05: Endpoints.plist release values come from Config/Hosting.json
run legal-sync     $py -I tools/site/legal-sync.py --check       # M10.T06: in-app legal pages = site pages; D-006, 18+, 72 h rules
run release-docs   bash -c "python3 -I tools/release/checklist-check.py && actionlint .github/workflows/*.yml"   # M10.T08: checklist shape + workflow lint
run uninstall-page $py -I tools/ci/uninstall-page-check.py     # M8.T11: Help › How to Uninstall lists both ways + every path
run permission-calls $py -I tools/ci/permission-calls.py      # M8.T14: every system permission request in PermissionCoordinator
run data-paths      $py -I tools/ci/gen-paths.py --check          # M8.T10: antichat-paths.txt matches DataPaths.swift
run uitests-build   tools/ci/uitests-build.sh               # UITests target compiles (Q-015: not runnable here)
run licence-scan     $py -I tools/acknowledgments.py "${ack_args[@]}"
if [[ -x tools/.venv/bin/python ]]; then
  run dev-catalog    tools/.venv/bin/python -I tools/dev/gen-dev-catalog.py --check
fi

echo "== make audit =="
printf '%s\n' "${summary[@]}"
exit $fail
