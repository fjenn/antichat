"""Negative self-tests for tools/ci/devfeed-guard.py (RC review P2-8): the guarded sources copied into a temp root,
one seeded violation per test; a fake app bundle for the artefact checks."""
import plistlib
import shutil
import subprocess
import sys

from conftest import CI, ROOT, load

g = load("devfeed-guard")


def tree(tmp_path):
    for rel in (g.UPDATE_STATE, g.UPDATER_SERVICE, g.BUILD_RELEASE, g.TEST_PUB):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    return tmp_path


def run(root, *args):
    return subprocess.run([sys.executable, "-I", str(CI / "devfeed-guard.py"), "--root", str(root), *args],
                          capture_output=True, text=True)


def edit(root, rel, old, new):
    p = root / rel
    s = p.read_text(encoding="utf-8")
    assert old in s, old
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


def app(tmp_path, key, binary=b"\x00code\x00"):
    a = tmp_path / "rel/AntiChat.app/Contents"
    (a / "MacOS").mkdir(parents=True)
    (a / "MacOS/AntiChat").write_bytes(binary)
    (a / "Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": key} if key else {}))
    return a.parent


def test_clean_tree_passes(tmp_path):
    out = run(tree(tmp_path))
    assert out.returncode == 0, out.stderr


def test_ungated_dev_feed_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, g.UPDATE_STATE, "#if DEBUG || ANTICHAT_DEV_FEED\n        true", "#if true\n        true")
    out = run(r)
    assert out.returncode == 1 and "devFeedAllowed" in out.stderr


def test_ungated_override_read_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, g.UPDATE_STATE, "    public static func current(", '    static let leak = "AntiChatFeedURLOverride"\n\n    public static func current(')
    out = run(r)
    assert out.returncode == 1 and "outside a" in out.stderr


def test_resolve_without_refusal_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, g.UPDATE_STATE, 'if dev, !devFeedAllowed { return UpdateFeed(url: "", devKeys: true) }', "")
    out = run(r)
    assert out.returncode == 1 and "resolve" in out.stderr


def test_sparkle_started_without_feed_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, g.UPDATER_SERVICE, "guard !feed.isDisabled", "guard true")
    out = run(r)
    assert out.returncode == 1 and "start()" in out.stderr


def test_dev_feed_for_devid_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, g.BUILD_RELEASE, '[[ "$keys" == dev && "$mode" != devid ]] && conditions=', '[[ "$keys" == dev ]] && conditions=')
    out = run(r)
    assert out.returncode == 1 and "ANTICHAT_DEV_FEED must be added" in out.stderr


def test_release_app_with_test_key_fails(tmp_path):
    r = tree(tmp_path)
    test_key = (ROOT / g.TEST_PUB).read_text().splitlines()[0].strip()
    a = app(tmp_path, test_key)
    assert run(r, "--app", str(a)).returncode == 0  # an adhoc/dev build may carry it
    out = run(r, "--app", str(a), "--release")
    assert out.returncode == 1 and "test key" in out.stderr


def test_release_app_with_override_compiled_in_fails(tmp_path):
    r = tree(tmp_path)
    out = run(r, "--app", str(app(tmp_path, "PRODKEY=", b"\x00AntiChatFeedURLOverride\x00")), "--release")
    assert out.returncode == 1 and "carries the AntiChatFeedURLOverride key" in out.stderr


def test_release_app_with_production_key_passes(tmp_path):
    r = tree(tmp_path)
    out = run(r, "--app", str(app(tmp_path, "PRODKEY=")), "--release")
    assert out.returncode == 0, out.stderr
