"""Self-tests for tools/ci/bundle-secret-scan.py (M7.T10, AT-255 c1): a planted fake Composio key, the variable name,
a random high-entropy string and a PEM private key fail; digests, UUIDs, public-key PEM blocks and mangled symbols
pass. Run: tools/.venv/bin/python -I -m pytest tools/ci/tests -q
"""
from __future__ import annotations

import sys
from pathlib import Path

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))

from conftest import load

bs = load("bundle-secret-scan")
CFG = bs.read_patterns(CI / "secret-patterns.yml")


def scan(tmp_path: Path, content: bytes, name: str = "Contents/MacOS/AntiChat") -> list[dict]:
    app = tmp_path / "Fake.app"
    f = app / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_bytes(content)
    return bs.scan(app, CFG)[0]


CLEAN = (
    b"\x00AntiChat\x00e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\x00"
    b"3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e\x00Lfhwtsep1tKBCxpS4LkzzJhO7uuNCWyI7p/eS8X8hlQ=\x00"
    b"_TtC15OsaurusVendoredP33_D6D5CC6D5E9E35B41227B2CFF626509F10ChunkQueue\x00"
    b"-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq8Xh2Kd9vQz7Lr4Wn1Ty5Bc3Mf6Hj0Pa\n"
    b"-----END PUBLIC KEY-----\x00"
)


def test_clean_bundle_passes(tmp_path):
    assert scan(tmp_path, CLEAN) == []


def test_planted_composio_key_fails(tmp_path):
    rules = {f["rule"] for f in scan(tmp_path, CLEAN + b"\x00ak_FAKEfakeFAKE0123456789xyz\x00")}
    assert "composio-project-key" in rules


def test_consumer_key_and_env_name_fail(tmp_path):
    rules = {f["rule"] for f in scan(tmp_path, b"\x00ck_FAKE00000000000000\x00COMPOSIO_API_KEY\x00")}
    assert rules == {"composio-consumer-key", "composio-env-name"}


def test_random_high_entropy_fails(tmp_path):
    found = scan(tmp_path, b"\x00Q7vK2mXp9ZtR4bWn8YcJ3hLd6FsG1aEu0NqT5\x00", "Contents/Resources/conf.txt")
    assert [f["rule"] for f in found] == ["high-entropy"]
    assert "Q7vK2mXp9Z" not in found[0]["preview"]  # redacted


def test_private_key_pem_fails(tmp_path):
    rules = {f["rule"] for f in scan(tmp_path, b"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----\n")}
    assert "private-key-pem" in rules


def test_pem_parser_header_strings_pass(tmp_path):
    assert scan(tmp_path, b"\x00-----BEGIN RSA PRIVATE KEY-----\x00-----END RSA PRIVATE KEY-----\x00") == []


def test_media_exempt_from_entropy_only(tmp_path):
    assert scan(tmp_path, b"\x00Q7vK2mXp9ZtR4bWn8YcJ3hLd6FsG1aEu0NqT5\x00", "Contents/Resources/a.png") == []
    assert scan(tmp_path, b"\x00ak_FAKEfakeFAKE0123456789xyz\x00", "Contents/Resources/b.png") != []
