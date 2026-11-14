"""PinnedKeys / CatalogKeyRotation (M10.T04 AT-305 check 4, generator side): a fork's Config/Keys.*.plist alone
changes the pinned keys; a release plist with test keys produces the #error that stops the build; swiftc agrees."""
from __future__ import annotations

import base64
import importlib.util
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

REL = Path(__file__).resolve().parents[1]
ROOT = REL.parents[1]
spec = importlib.util.spec_from_file_location("gen_keys", REL / "gen-keys-swift.py")
gk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gk)


def key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


def fork(tmp: Path, release: dict | None) -> Path:
    (tmp / "Config").mkdir(parents=True)
    (tmp / "catalog/test-keys").mkdir(parents=True)
    shutil.copy(ROOT / "Config/Keys.dev.plist", tmp / "Config/Keys.dev.plist")
    shutil.copy(ROOT / "catalog/test-keys/FINGERPRINTS", tmp / "catalog/test-keys/FINGERPRINTS")
    rel = plistlib.loads((ROOT / "Config/Keys.release.plist").read_bytes())
    rel.update(release or {})
    (tmp / "Config/Keys.release.plist").write_bytes(plistlib.dumps(rel))
    return tmp


def test_committed_file_is_current():
    assert gk.render(ROOT) == (ROOT / gk.OUT).read_text()


def dev_test_keys() -> dict:
    """The committed test keys (Config/Keys.dev.plist), seeded into a fork's release plist (the repo's own release
    plist holds the production keys since the M10.T04 ceremony)."""
    return plistlib.loads((ROOT / "Config/Keys.dev.plist").read_bytes())


def test_test_keys_in_release_plist_produce_the_error(tmp_path):
    root = fork(tmp_path, dev_test_keys())
    assert gk.release_problems(root)
    assert '#error("PinnedKeys' in gk.render(root)


def test_fork_keys_are_pinned_and_buildable(tmp_path):
    a, b, s = key(), key(), key()
    root = fork(tmp_path, {"CatalogPublicKeyA": a, "CatalogPublicKeyB": b, "SparklePublicEDKey": s})
    assert gk.release_problems(root) == []
    text = gk.render(root)
    assert "#error" not in text and f'"{a}", "{b}"' in text


def test_sparkle_and_catalog_keys_must_differ(tmp_path):
    a = key()
    root = fork(tmp_path, {"CatalogPublicKeyA": a, "CatalogPublicKeyB": key(), "SparklePublicEDKey": a})
    assert any("three different" in p for p in gk.release_problems(root))


@pytest.mark.skipif(shutil.which("swiftc") is None, reason="needs swiftc")
def test_swiftc_stops_only_release_builds(tmp_path):
    src = tmp_path / "PinnedKeys.swift"
    src.write_text(gk.render(fork(tmp_path / "fork", dev_test_keys())))
    dev = subprocess.run(["swiftc", "-typecheck", str(src)], capture_output=True, text=True)
    assert dev.returncode == 0, dev.stderr
    rel = subprocess.run(["swiftc", "-typecheck", "-D", "ANTICHAT_RELEASE_KEYS", str(src)], capture_output=True, text=True)
    assert rel.returncode != 0 and "still holds test keys" in rel.stderr
