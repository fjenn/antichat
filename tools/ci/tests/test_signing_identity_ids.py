import shutil
import subprocess

from conftest import ROOT

FILES = ["tools/at/ft-release-probe.sh", "tools/at/ft-release-probe/main.swift", "tools/visual/vq-05-release.sh"]


def _tree(tmp_path):
    for f in FILES:
        (tmp_path / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / f, tmp_path / f)
    shutil.copytree(ROOT / "App/IntegrationTests/FileTools", tmp_path / "App/IntegrationTests/FileTools")
    return tmp_path


def _run(root):
    return subprocess.run(["python3", "-I", str(ROOT / "tools/ci/signing-identity-ids.py"), "--root", str(root)],
                          capture_output=True, text=True)


def test_clean_tree_passes(tmp_path):
    assert _run(_tree(tmp_path)).returncode == 0


def test_probe_on_shipped_ids_fails(tmp_path):
    t = _tree(tmp_path)
    p = t / "tools/at/ft-release-probe.sh"
    p.write_text(p.read_text().replace('PROBE_ID="app.antichat.AntiChat.relprobe-$MODE"', 'PROBE_ID="app.antichat.AntiChat"'))
    r = _run(t)
    assert r.returncode == 1 and "relprobe" in r.stdout


def test_client_on_shipped_service_fails(tmp_path):
    t = _tree(tmp_path)
    m = t / "tools/at/ft-release-probe/main.swift"
    m.write_text(m.read_text() + "\nlet x = FileToolsClient(network: false)\n")
    assert _run(t).returncode == 1


def test_release_test_without_guard_fails(tmp_path):
    t = _tree(tmp_path)
    f = t / "App/IntegrationTests/FileTools/SecuritySuiteTests.swift"
    f.write_text(f.read_text().replace("    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }\n", ""))
    r = _run(t)
    assert r.returncode == 1 and "SecuritySuiteTests" in r.stdout


def test_probe_without_slot_ids_fails(tmp_path):
    # A-M6-T21a (a): every slot service needs its own probe id (the registry and the rewrite cover all of them).
    t = _tree(tmp_path)
    p = t / "tools/at/ft-release-probe.sh"
    p.write_text(p.read_text().replace('sid="$PROBE_ID.FileTools${v:+.$v}.slot$k"', 'sid="$PROBE_ID.FileTools${v:+.$v}"'))
    assert _run(t).returncode == 1


def test_probe_on_the_shared_leaser_fails(tmp_path):
    t = _tree(tmp_path)
    m = t / "tools/at/ft-release-probe/main.swift"
    m.write_text(m.read_text() + "\nlet y = FileToolsClient(network: true, slots: FileToolsSlots.shared)\n")
    assert _run(t).returncode == 1


def test_release_leg_on_shipped_ids_fails(tmp_path):
    t = _tree(tmp_path)
    v = t / "tools/visual/vq-05-release.sh"
    v.write_text(v.read_text().replace('PROBE_ID="app.antichat.AntiChat.relprobe-adhoc"', 'PROBE_ID="app.antichat.AntiChat"'))
    r = _run(t)
    assert r.returncode == 1 and "vq-05-release.sh" in r.stdout


def test_release_leg_signing_the_shipped_build_fails(tmp_path):
    t = _tree(tmp_path)
    v = t / "tools/visual/vq-05-release.sh"
    v.write_text(v.read_text().replace('--app "$HOST"', '--app "$APP"'))
    r = _run(t)
    assert r.returncode == 1 and "only sign the probe host" in r.stdout


def test_other_script_resigning_and_touching_services_fails(tmp_path):
    t = _tree(tmp_path)
    (t / "tools/visual/other.sh").write_text('tools/release/sign.sh --app "$X"\nls "$X/Contents/XPCServices/AntiChatFileTools.xpc"\n')
    r = _run(t)
    assert r.returncode == 1 and "other.sh" in r.stdout
