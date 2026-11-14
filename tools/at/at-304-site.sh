#!/bin/bash
# AT-304 (M10.T05; R-304 AC1–AC3) — the legs that run without the owner: `make site` (gen-pages, legal-sync, astro
# build, post-build security.txt + CSP, site-audit, vitest platform check), linkinator over site/dist (0 broken
# internal links), then `make site-test`: tools/site/hosting-check.py --dev over dist served on 127.0.0.1 with its
# vercel.json headers, and the Playwright CSP check (every page 0 violations / 0 blocked / 0 off-host requests; help
# search "disk" → FAQ). The strict hosting check (no dev hosts) runs too and its findings are printed, not gating:
# the catalog's runtime URLs stay on the dev host until the release sets them (preflight lists it). Legs that need the
# deployed host or the owner (own domain Q3, preview deploy, `hosting-check.py --url`) are listed in
# build/at/AT-304/pending.txt, so result.json stays pass:false until they run.
# Usage: tools/at/run.sh AT-304 -- tools/at/at-304-site.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
make site
# The canonical links point at the site host of Config/Hosting.json, which serves nothing until the owner deploys
# (M10-owner-steps §4); they are external until then and are checked by the preview-deploy leg instead.
host=$(python3 -I -c "import json,urllib.parse;print(urllib.parse.urlparse(json.load(open('Config/Hosting.json'))['siteURL']).netloc)")
npx --prefix site linkinator site/dist --recurse --skip "^https://(github.com|huggingface.co|${host//./\\.})"
make site-test
echo "→ strict hosting check (release form, dev hosts refused; informational until the release sets runtime URLs)"
python3 -I tools/site/hosting-check.py --json build/site-test/hosting-check-strict.json || true
