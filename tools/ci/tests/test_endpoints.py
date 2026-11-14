"""Negative self-tests for tools/ci/endpoints-check.py (M8.T09 fix): the plist and the guarded sources copied into a
temp root, one seeded violation per test."""
import shutil
import subprocess
import sys

from conftest import CI, ROOT, load

ep = load("endpoints-check")


def tree(tmp_path):
    for rel in (ep.PLIST, ep.SWIFT, ep.SHEET, ep.CRASH):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    return tmp_path


def run(root, *args):
    return subprocess.run([sys.executable, "-I", str(CI / "endpoints-check.py"), "--root", str(root), *args],
                          capture_output=True, text=True)


def edit(root, rel, old, new):
    p = root / rel
    s = p.read_text(encoding="utf-8")
    assert old in s, old
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


def test_clean_tree_passes(tmp_path):
    assert run(tree(tmp_path)).returncode == 0


def test_half_filled_value_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, ep.PLIST, "<string>finn.jennen@gmail.com</string>", "<string>support at antichat</string>")
    out = run(r)
    assert out.returncode == 1 and "SupportEmail" in out.stderr


def test_release_guard_removed_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, ep.SWIFT, "allowPlaceholders: Bool = AppDatabaseFlags.isDebugBuild", "allowPlaceholders: Bool = true")
    out = run(r)
    assert out.returncode == 1 and "release guard" in out.stderr


def test_strict_fails_on_placeholders(tmp_path):
    r = tree(tmp_path)
    edit(r, ep.PLIST, "<string>finn.jennen@gmail.com</string>", "<string>support@antichat.invalid</string>")
    out = run(r, "--strict")
    assert out.returncode == 1 and "still a placeholder" in out.stderr


def test_strict_fails_on_loopback_relay(tmp_path):
    """RC review P1-2: the dev relay URL (http://127.0.0.1:3000) must not reach a release build."""
    r = tree(tmp_path)
    edit(r, ep.PLIST, "<key>RelayURL</key>\n\t<string>https://antichat-relay.vercel.app</string>", "<key>RelayURL</key>\n\t<string>http://127.0.0.1:3000</string>")
    out = run(r, "--strict")
    assert out.returncode == 1 and "RelayURL" in out.stderr


def test_strict_fails_on_empty_relay(tmp_path):
    """Release 2: the relay is deployed, so an empty RelayURL (release 1's "hide Composio" state) fails --strict."""
    r = tree(tmp_path)
    assert "RelayURL" not in run(r, "--strict").stderr
    edit(r, ep.PLIST, "<key>RelayURL</key>\n\t<string>https://antichat-relay.vercel.app</string>", "<key>RelayURL</key>\n\t<string></string>")
    out = run(r, "--strict")
    assert out.returncode == 1 and "RelayURL" in out.stderr


def test_relay_url_rule():
    assert ep.relay_ok("https://relay.antichat.app")
    assert ep.relay_ok("https://antichat-relay.vercel.app/")
    for bad in ("http://127.0.0.1:3000", "https://127.0.0.1", "https://localhost:3000", "http://relay.antichat.app",
                "https://relay.placeholder.dev", "https://[::1]:3000", ""):
        assert not ep.relay_ok(bad), bad
