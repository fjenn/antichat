#!/usr/bin/env python3
"""After `astro build` (M10.T05 steps 3, 5). `python3 -I`; stdlib only.
  - dist/.well-known/security.txt (RFC 9116): Contact from Config/Hosting.json, Expires = build day + 365 d,
    Policy/Canonical on the site URL, Preferred-Languages en;
  - site/vercel.json and dist/vercel.json (the same file: `make site-deploy-*` deploys with `--cwd dist`, so the
    copy inside dist is the one Vercel reads; serve-site.py applies it locally): security headers incl. a CSP whose script-src lists the sha256 of every inline <script> in
    dist (Starlight's theme script), 'wasm-unsafe-eval' for Pagefind, no third-party origin; no analytics.
Usage: post-build.py site/dist"""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INLINE = re.compile(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", re.S)


def main() -> int:
    dist = Path(sys.argv[1])
    h = json.loads((ROOT / "Config/Hosting.json").read_text())
    site = h["siteURL"].rstrip("/")
    exp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=365)).strftime("%Y-%m-%dT00:00:00Z")
    wk = dist / ".well-known"
    wk.mkdir(parents=True, exist_ok=True)
    (wk / "security.txt").write_text(f"Contact: mailto:{h['securityEmail']}\nExpires: {exp}\n"
                                     f"Policy: {site}/legal/security/\nPreferred-Languages: en\n"
                                     f"Canonical: {site}/.well-known/security.txt\n")
    hashes = sorted({"'sha256-" + base64.b64encode(hashlib.sha256(m.group(1).encode()).digest()).decode() + "'"
                     for f in dist.rglob("*.html") for m in INLINE.finditer(f.read_text())})
    csp = ("default-src 'self'; img-src 'self' data:; script-src 'self' 'wasm-unsafe-eval' " + " ".join(hashes) +
           "; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action mailto:")
    cfg = {"$schema": "https://openapi.vercel.sh/vercel.json",
           "headers": [{"source": "/(.*)", "headers": [
               {"key": "Content-Security-Policy", "value": csp},
               {"key": "Referrer-Policy", "value": "no-referrer"},
               {"key": "X-Content-Type-Options", "value": "nosniff"},
               {"key": "Permissions-Policy", "value": "interest-cohort=(), browsing-topics=()"}]}]}
    text = json.dumps(cfg, indent=2) + "\n"
    (ROOT / "site/vercel.json").write_text(text)
    (dist / "vercel.json").write_text(text)
    print(f"post-build: security.txt (expires {exp[:10]}), vercel.json CSP with {len(hashes)} inline-script hash(es)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
