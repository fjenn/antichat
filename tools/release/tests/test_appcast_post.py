"""AppcastPostTests (M10.T03 AT-219 AC5) + PR5 checker self-tests. `make test-release-tools`."""
from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

REL = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), REL / f"{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


post = load("appcast-post")
pr5 = load("pr5-check")

FEED = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><title>AntiChat</title>
    <item><title>1.1.0</title><sparkle:version>20</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
      <enclosure url="https://x/AntiChat-1.1.0.dmg" length="1" type="application/octet-stream" sparkle:edSignature="s"/></item>
    <item><title>1.0.0</title><sparkle:version>10</sparkle:version><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <enclosure url="https://x/AntiChat-1.0.0.dmg" length="1" type="application/octet-stream" sparkle:edSignature="s"/></item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: abc
length: 1
-->
"""
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def items(xml: str):
    import xml.etree.ElementTree as ET
    return {i.findtext(f"{S}shortVersionString"): i for i in ET.fromstring(xml).findall("channel/item")}


def test_required_tags_added_and_old_signature_dropped(tmp_path):
    out = post.process(FEED, tmp_path)
    assert "sparkle-signatures" not in out
    for it in items(out).values():
        assert it.findtext(f"{S}minimumSystemVersion") == "26.0"
        assert it.findtext(f"{S}hardwareRequirements") == "arm64"
        assert int(it.findtext(f"{S}phasedRolloutInterval")) * 6 >= 3 * 86400
        assert it.find(f"{S}criticalUpdate") is None and it.find(f"{S}channel") is None


def test_critical_and_beta_from_notes_json(tmp_path):
    (tmp_path / "1.1.0.json").write_text(json.dumps({"critical": True, "prerelease": True}))
    it = items(post.process(FEED, tmp_path))["1.1.0"]
    assert it.find(f"{S}criticalUpdate") is not None
    assert it.findtext(f"{S}channel") == "beta"
    assert items(post.process(FEED, tmp_path))["1.0.0"].find(f"{S}criticalUpdate") is None


def test_pulled_release_is_removed(tmp_path):
    assert set(items(post.process(FEED, tmp_path, pull=["1.1.0"]))) == {"1.0.0"}


def test_test_feed_has_no_phased_rollout(tmp_path):
    for it in items(post.process(FEED, tmp_path, phased=False)).values():
        assert it.find(f"{S}phasedRolloutInterval") is None


def req(ua="AntiChat/1.1.0 Sparkle/2.10.1", path="/appcast-dev.xml", **extra):
    h = {"Host": "192.168.64.1:8765", "User-Agent": ua, "Accept": "*/*", "Accept-Encoding": "gzip"}
    h.update(extra)
    return {"method": "GET", "path": path, "headers": h}


def test_pr5_passes_identical_installs():
    assert pr5.check([[req()], [req()]], "/appcast-dev.xml") == []


def test_pr5_fails_on_identifiers():
    assert pr5.check([[req(path="/appcast-dev.xml?appVersion=1&cpu64bit=1")]], "/appcast-dev.xml")
    assert pr5.check([[req(Cookie="id=1")]], "/appcast-dev.xml")
    assert pr5.check([[req()], [req(**{"Accept-Language": "en"})], [req(**{"Accept-Language": "de"})]], "/appcast-dev.xml")
    assert pr5.check([[req(ua="Mozilla/5.0")]], "/appcast-dev.xml")
    assert pr5.check([[]], "/appcast-dev.xml")


def test_keep_urls_restores_earlier_release_tags():
    """Release 2: one --download-url-prefix (…/v1.1.0/) must not move 1.0.0's archive off its own tag."""
    prev = re.sub(r"<item><title>1\.1\.0.*?</item>", "", FEED, flags=re.S)  # the feed before 1.1.0
    prev = prev.replace("https://x/AntiChat-1.0.0.dmg", "https://gh/download/v1.0.0/AntiChat-1.0.0.dmg")
    keep = post.enclosure_urls(prev)
    out = post.process(FEED.replace("https://x/", "https://gh/download/v1.1.0/"), Path("/nonexistent"), keep_urls=keep)
    assert "https://gh/download/v1.0.0/AntiChat-1.0.0.dmg" in out
    assert "https://gh/download/v1.1.0/AntiChat-1.1.0.dmg" in out
