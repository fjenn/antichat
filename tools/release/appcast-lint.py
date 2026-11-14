#!/usr/bin/env python3
"""Appcast lint (M10.T03 AT-219 AC1/AC5; ci-release §6.2). Run with `python3 -I`.

Checks a feed and exits 1 on any problem:
  - the feed signature is valid (`sign_update --verify FEED` with the feed's key; Sparkle ≥ 2.9 signed feeds);
  - every item: enclosure with url, length, sparkle:edSignature, which verifies against the archive in
    --archives DIR (`sign_update --verify ARCHIVE SIG`) when that file is present;
    sparkle:minimumSystemVersion 26.0; sparkle:hardwareRequirements arm64;
    sparkle:phasedRolloutInterval × 6 ≥ 3 days (Sparkle's 7 groups, group 0 at release) unless --test-feed;
  - production feed (--production): no UNNOTARIZED/DEVKEYS archive, every enclosure https.
Usage: appcast-lint.py FEED.xml --key KEYFILE [--archives DIR] [--production] [--test-feed] [--sparkle-bin DIR]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse

S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ROOT = Path(__file__).resolve().parents[2]


def lint(feed: Path, key: Path, sparkle_bin: Path, archives: Path | None, production: bool, test_feed: bool) -> list[str]:
    bad: list[str] = []
    su = str(sparkle_bin / "sign_update")
    r = subprocess.run([su, "--verify", "--ed-key-file", str(key), str(feed)], capture_output=True, text=True)
    if r.returncode != 0:
        bad.append(f"feed signature invalid or missing: {(r.stderr or r.stdout).strip()[:200]}")
    items = ET.parse(feed).getroot().findall("channel/item")
    if not items:
        bad.append("no <item> in the feed")
    for item in items:
        title = (item.findtext("title") or "?").strip()
        enc = item.find("enclosure")
        if enc is None:
            bad.append(f"{title}: no enclosure")
            continue
        url, sig = enc.get("url", ""), enc.get(f"{S}edSignature")
        if not sig:
            bad.append(f"{title}: enclosure without sparkle:edSignature")
        if not enc.get("length"):
            bad.append(f"{title}: enclosure without length")
        name = Path(urlparse(url).path).name
        if archives and sig and (archives / name).exists():
            v = subprocess.run([su, "--verify", "--ed-key-file", str(key), str(archives / name), sig],
                               capture_output=True, text=True)
            if v.returncode != 0:
                bad.append(f"{title}: edSignature does not verify {name}")
        if (item.findtext(f"{S}minimumSystemVersion") or "").strip() != "26.0":
            bad.append(f"{title}: minimumSystemVersion is not 26.0")
        if (item.findtext(f"{S}hardwareRequirements") or "").strip() != "arm64":
            bad.append(f"{title}: hardwareRequirements is not arm64")
        interval = item.findtext(f"{S}phasedRolloutInterval")
        if not test_feed:
            if not interval or int(interval) * 6 < 3 * 86400:
                bad.append(f"{title}: phasedRolloutInterval {interval} gives < 3 days (×6 groups)")
        if production:
            if "UNNOTARIZED" in name or "DEVKEYS" in name:
                bad.append(f"{title}: production feed carries a labelled archive {name}")
            if not url.startswith("https://"):
                bad.append(f"{title}: production enclosure is not https ({url})")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("feed")
    ap.add_argument("--key", default=str(ROOT / "catalog/test-keys/sparkle-test.key"))
    ap.add_argument("--archives")
    ap.add_argument("--production", action="store_true")
    ap.add_argument("--test-feed", action="store_true")
    ap.add_argument("--sparkle-bin", default=str(ROOT / "build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"))
    a = ap.parse_args()
    bad = lint(Path(a.feed), Path(a.key), Path(a.sparkle_bin), Path(a.archives) if a.archives else None,
               a.production, a.test_feed)
    for b in bad:
        print(b)
    print(f"appcast-lint: {a.feed}: {'ok' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
