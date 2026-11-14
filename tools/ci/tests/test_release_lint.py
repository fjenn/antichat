"""M10.T01: tools/ci/release-lint.py fails on each seeded violation (in a scratch tree via --root) and passes the
real tree. Run: tools/.venv/bin/python -I -m pytest tools/ci/tests/test_release_lint.py -q"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

CI = Path(__file__).resolve().parents[1]
ROOT = CI.parents[1]
spec = importlib.util.spec_from_file_location("release_lint", CI / "release-lint.py")
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>{}</dict></plist>"""


def tree(tmp: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    (tmp / "tools/release/entitlements").mkdir(parents=True, exist_ok=True)
    return tmp


def test_real_tree_passes():
    assert lint.check(ROOT) == []


@pytest.mark.parametrize("files,needle", [
    ({"tools/release/x.sh": 'codesign --force --deep -s "$ID" app\n'}, "--deep"),
    ({"tools/release/x.sh": "xcrun notarytool submit a.zip --apple-id me@x --password abc\n"}, "keychain-profile"),
    ({"tools/release/entitlements/a.plist": PLIST.format("<key>com.apple.security.cs.allow-jit</key><true/>")}, "allow-jit"),
    ({"tools/release/entitlements/AntiChat.plist":
      PLIST.format("<key>com.apple.security.cs.disable-library-validation</key><true/>")}, "disable-library-validation"),
    ({"Config/devid.p12": "x"}, "certificate/key file"),
])
def test_seeded_violation_fails(tmp_path, files, needle):
    bad = lint.check(tree(tmp_path, files))
    assert len(bad) == 1 and needle in bad[0], bad


@pytest.mark.parametrize("files", [
    {"tools/release/x.sh": "codesign --verify --deep --strict app  # verification may recurse\n"},
    {"tools/release/x.sh": "# never codesign --deep when signing\n"},
    {"tools/release/x.sh": 'xcrun notarytool submit a.zip --keychain-profile "$p" --wait\n'},
    {"tools/release/entitlements/adhoc-extra.plist":
     PLIST.format("<key>com.apple.security.cs.disable-library-validation</key><true/>")},
    {"fixtures/catalog/test-keys/x.pem": "x"},
])
def test_allowed_forms_pass(tmp_path, files):
    assert lint.check(tree(tmp_path, files)) == []
