#!/usr/bin/env python3
"""AT-304 site audit (M10.T05; R-304 AC1/AC3). `python3 -I`; stdlib only.
Checks site/dist: every required page exists and is non-empty; no <script src>/<link href>/<img src>/<iframe> to
another host; no analytics snippets; no server functions (api/); the privacy page states aggregate counts;
security.txt present with Contact/Expires. `--prod` also fails on placeholders (Hosting.json .invalid/placeholder
values, the first-open screenshot placeholder) — a production deploy needs a clean --prod run.
Usage: site-audit.py site/dist [--prod]"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = ["index.html", "download/index.html", "requirements/index.html", "changelog/index.html",
            "help/index.html", "help/getting-started/index.html", "help/faq/index.html",
            "help/connections/index.html", "help/skills/index.html", "help/images-video-voice/index.html",
            "help/files/index.html", "help/evil-mode/index.html", "help/memory/index.html", "help/privacy/index.html",
            "help/disk-full/index.html", "help/updating/index.html", "help/report-a-problem/index.html",
            "help/troubleshooting/index.html", "help/uninstall/index.html", "help/status/index.html",
            "evil-mode/index.html", "acceptable-use/index.html", "legal/terms/index.html",
            "legal/privacy/index.html", "legal/evil-mode-terms/index.html", "legal/abuse/index.html",
            "legal/licenses/index.html", "legal/model-licenses/index.html", "legal/security/index.html",
            ".well-known/security.txt", "appcast-dev.xml", "catalog/v2/catalog.json", "catalog/v2/catalog.json.sig"]
EXTERNAL = re.compile(r"<(?:script|img|iframe)[^>]+src=\"(https?:)?//|<link[^>]+href=\"(https?:)?//[^\"]*\"[^>]*rel=\"(?:stylesheet|preload|modulepreload)", re.I)
ANALYTICS = re.compile(r"gtag\(|googletagmanager|plausible|umami|_vercel/insights|segment\.com|mixpanel|hotjar", re.I)


def audit(dist: Path, prod: bool) -> list[str]:
    bad = [f"missing or empty: {p}" for p in REQUIRED if not (dist / p).exists() or (dist / p).stat().st_size == 0]
    for f in dist.rglob("*.html"):
        t = f.read_text(errors="replace")
        if EXTERNAL.search(t):
            bad.append(f"{f.relative_to(dist)}: loads a resource from another host")
        if ANALYTICS.search(t):
            bad.append(f"{f.relative_to(dist)}: analytics snippet")
    if (dist / "api").exists() or (ROOT / "site/api").exists():
        bad.append("server functions (api/) present")
    priv = dist / "legal/privacy/index.html"
    if priv.exists() and "aggregate download counts" not in priv.read_text():
        bad.append("privacy page lacks the aggregate-counts sentence")
    st = dist / ".well-known/security.txt"
    if st.exists() and not all(k in st.read_text() for k in ("Contact:", "Expires:")):
        bad.append("security.txt lacks Contact/Expires")
    if prod:
        h = json.loads((ROOT / "Config/Hosting.json").read_text())
        for k, v in h.items():
            if not k.startswith("_") and (".invalid" in v or "placeholder" in v):
                bad.append(f"--prod: Config/Hosting.json {k}={v} is a placeholder")
        img = dist / "img/install-first-open.png"
        if not img.exists() or img.stat().st_size < 10_000:
            bad.append("--prod: img/install-first-open.png is the placeholder (replace with the devid capture)")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dist")
    ap.add_argument("--prod", action="store_true")
    a = ap.parse_args()
    bad = audit(Path(a.dist), a.prod)
    for b in bad:
        print(b)
    print(f"site-audit: {'ok' if not bad else f'{len(bad)} problem(s)'}{' (prod)' if a.prod else ''}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
