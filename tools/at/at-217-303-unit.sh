#!/bin/bash
# AT-217 (M10.T06; R-217) and AT-303 (M10.T07; R-303) — the legs that run without automation mode:
#   AT-217  tools/site/legal-sync.py --check (pages present in site + app, equal versions/dates, D-006 block + 18+,
#           "72 hours" + address + form, aggregate-counts sentence) and HelpAndLegalTests (bundled legal pages parse,
#           every one versioned and dated);
#   AT-303  HelpAndLegalTests (Help opens the browser only when online, What's new rules / once per version,
#           committed notes decode with 3–5 items, the tour lists the installed packs).
# Both also compile the XCUITest legs (tools/ci/uitests-build.sh: App/UITests/LegalUITests.swift, HelpUITests.swift);
# running them needs automation mode (Q-015), so `make test-ui FILTER=LegalUITests|HelpUITests` is listed in
# build/at/<AT>/pending.txt. AT-303 also runs the website search leg (Playwright, `make site-test`; builds the site
# first when site/dist is missing).
# Usage: tools/at/run.sh AT-217 -- tools/at/at-217-303-unit.sh legal   |   … AT-303 -- tools/at/at-217-303-unit.sh help
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "${1:-}" = legal ]; then python3 -I tools/site/legal-sync.py --check; fi
make test-unit FILTER=HelpAndLegalTests
tools/ci/uitests-build.sh
if [ "${1:-}" = help ]; then
  [ -f site/dist/index.html ] || make site
  (cd site && npx playwright test csp -g 'help search')
fi
