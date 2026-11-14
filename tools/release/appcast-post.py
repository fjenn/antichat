#!/usr/bin/env python3
"""Appcast post-processing (M10.T03 step 7; R-219 AC1/AC5). Run with `python3 -I`; stdlib only.

`generate_appcast` (Sparkle 2.10.1) writes the items; this adds what it does not, per item:
  sparkle:minimumSystemVersion 26.0 (D-014), sparkle:hardwareRequirements arm64, sparkle:phasedRolloutInterval
  86400 (7 groups → 7 days ≥ 3 days; omitted with --no-phased for the test feed), sparkle:criticalUpdate when
  notes/<ver>.json has "critical": true, sparkle:channel beta when it has "prerelease": true.
`--keep-urls PREV.xml` restores the enclosure URL each archive had in the previous feed: generate_appcast applies the
one --download-url-prefix to every archive, but each GitHub release serves its assets under its own tag
(…/download/v0.0.1/ vs …/download/v0.0.2/), so earlier items must keep their URL (release 2).
`--pull VERSION` removes that release's item (pulling a release, CHECKLIST.md). The feed must be re-signed
afterwards (`sign_update --ed-key-file … appcast.xml`; appcast.sh does it), because any edit invalidates the
embedded signature.
Usage: appcast-post.py FEED.xml --notes-dir notes [--no-phased] [--keep-urls PREV.xml] [--pull VER]…
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)
S = f"{{{SPARKLE}}}"
SIG_COMMENT = re.compile(r"<!--\s*sparkle-signatures:.*?-->\s*", re.S)


def item_version(item: ET.Element) -> str | None:
    v = item.find(f"{S}shortVersionString")
    if v is not None and v.text:
        return v.text.strip()
    enc = item.find("enclosure")
    return enc.get(f"{S}shortVersionString") if enc is not None else None


def set_child(item: ET.Element, tag: str, text: str | None) -> None:
    el = item.find(f"{S}{tag}")
    if el is None:
        el = ET.SubElement(item, f"{S}{tag}")
    el.text = text


def drop_child(item: ET.Element, tag: str) -> None:
    for el in item.findall(f"{S}{tag}"):
        item.remove(el)


def enclosure_urls(xml: str) -> dict[str, str]:
    """archive file name → its enclosure URL (items and their deltas)."""
    root = ET.fromstring(SIG_COMMENT.sub("", xml))
    return {u.rsplit("/", 1)[-1]: u for e in root.iter("enclosure") if (u := e.get("url"))}


def process(xml: str, notes_dir: Path, phased: bool = True, pull: list[str] | None = None,
            keep_urls: dict[str, str] | None = None) -> str:
    xml = SIG_COMMENT.sub("", xml)  # the old signature is invalid after any edit; appcast.sh re-signs
    root = ET.fromstring(xml)
    channel = root.find("channel")
    if channel is None:
        raise ValueError("no <channel>")
    for e in root.iter("enclosure"):
        name = (e.get("url") or "").rsplit("/", 1)[-1]
        if keep_urls and name in keep_urls:
            e.set("url", keep_urls[name])
    for item in list(channel.findall("item")):
        ver = item_version(item)
        if pull and ver in pull:
            channel.remove(item)
            continue
        meta = {}
        if ver and (notes_dir / f"{ver}.json").exists():
            meta = json.loads((notes_dir / f"{ver}.json").read_text())
        set_child(item, "minimumSystemVersion", "26.0")
        set_child(item, "hardwareRequirements", "arm64")
        if phased:
            set_child(item, "phasedRolloutInterval", "86400")
        else:
            drop_child(item, "phasedRolloutInterval")
        if meta.get("critical"):
            if item.find(f"{S}criticalUpdate") is None:
                ET.SubElement(item, f"{S}criticalUpdate")
        else:
            drop_child(item, "criticalUpdate")
        if meta.get("prerelease"):
            set_child(item, "channel", "beta")
        else:
            drop_child(item, "channel")
    ET.indent(root, space="    ")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("feed")
    ap.add_argument("--notes-dir", default="notes")
    ap.add_argument("--no-phased", action="store_true")
    ap.add_argument("--pull", action="append", default=[])
    ap.add_argument("--keep-urls", type=Path)
    a = ap.parse_args()
    p = Path(a.feed)
    keep = enclosure_urls(a.keep_urls.read_text()) if a.keep_urls and a.keep_urls.exists() and a.keep_urls.stat().st_size else None
    p.write_text(process(p.read_text(), Path(a.notes_dir), phased=not a.no_phased, pull=a.pull, keep_urls=keep))
    print(f"appcast-post: {p} ({'phased' if not a.no_phased else 'no phased rollout'}"
          f"{', pulled ' + ','.join(a.pull) if a.pull else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
