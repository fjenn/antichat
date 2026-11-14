#!/usr/bin/env python3
"""Hosting switch (M10.T05/T10; D-007/D-010; ci-release §7). Run with `python3 -I`.

Config/Hosting.json is the one place for public hosts (site URL = own domain or the interim host, the public
GitHub repo, the inboxes). This writes the derived release values into Config/Endpoints.plist (text-level, comments
kept): CatalogURL, DownloadURL, AppcastURL, AppcastDevURL, ReleasesURLPrefix, IssuesURL, SupportEmail, RelayURL (the
deployed Composio relay, `relayURL`). The
Debug twins (CatalogURLDev, DownloadURLDev → the local site) are left alone; Debug builds read them (Endpoints.swift).
  --check   exit 1 when Endpoints.plist differs from Hosting.json (make audit)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def derived(h: dict) -> dict[str, str]:
    site = h["siteURL"].rstrip("/")
    repo = h["githubRepo"]
    return {
        "CatalogURL": f"{site}/catalog/v2/catalog.json",
        "DownloadURL": f"{site}/download/",
        "AppcastURL": f"{site}/appcast.xml",
        "AppcastDevURL": f"{site}/appcast-dev.xml",
        "ReleasesURLPrefix": f"https://github.com/{repo}/releases/download/",
        "IssuesURL": f"https://github.com/{repo}/issues",
        "SupportEmail": h["supportEmail"],
        "RelayURL": h.get("relayURL", ""),
    }


def apply(text: str, values: dict[str, str]) -> str:
    for k, v in values.items():
        pat = re.compile(rf"(<key>{re.escape(k)}</key>\s*<string>)([^<]*)(</string>)")
        if pat.search(text):
            text = pat.sub(lambda m: m.group(1) + v + m.group(3), text)
        else:
            text = text.replace("</dict>\n</plist>", f"\t<key>{k}</key>\n\t<string>{v}</string>\n</dict>\n</plist>")
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    root = Path(a.root)
    h = json.loads((root / "Config/Hosting.json").read_text())
    p = root / "Config/Endpoints.plist"
    old = p.read_text()
    new = apply(old, derived(h))
    if a.check:
        print(f"set-hosting: {'ok' if new == old else 'Config/Endpoints.plist is out of sync with Config/Hosting.json'}")
        return 0 if new == old else 1
    p.write_text(new)
    print(f"set-hosting: Config/Endpoints.plist ← {h['siteURL']} / github.com/{h['githubRepo']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
