"""Negative self-tests for tools/ci/dev-modes-guard.py: developer test modes (bench, spike, probes, dev launch options,
environment variables and defaults keys) stay inside `#if DEBUG || ANTICHAT_PERF_HARNESS`, and no release bundle
carries one. Run: tools/.venv/bin/python -I -m pytest tools/ci/tests/test_dev_modes_guard.py -q"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from conftest import CI, ROOT, load

g = load("dev-modes-guard")
SRC = "Packages/UI/Sources/AntiChatUI/Thing.swift"
GATED = f"{g.GATE}\n%s\n#endif\n"
MACHO = b"\xcf\xfa\xed\xfe"


def tree(tmp: Path, files: dict[str, str], allow: str = "") -> Path:
    for rel, text in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    (tmp / "tools/ci").mkdir(parents=True, exist_ok=True)
    (tmp / g.ALLOW).write_text(allow, encoding="utf-8")
    return tmp


def run(root: Path, *args: str):
    return subprocess.run([sys.executable, "-I", str(CI / "dev-modes-guard.py"), "--root", str(root), *args],
                          capture_output=True, text=True)


def bundle(tmp: Path, name: str, data: bytes) -> Path:
    d = tmp / "AntiChat.app/Contents/MacOS"
    d.mkdir(parents=True, exist_ok=True)
    (d / name).write_bytes(data)
    return tmp / "AntiChat.app"


def test_real_tree_passes():
    out = run(ROOT)
    assert out.returncode == 0, out.stderr


def test_clean_tree_passes(tmp_path):
    out = run(tree(tmp_path, {SRC: "let a = Defaults[.theme]\n" + GATED % 'let b = CommandLine.arguments.contains("-Bench")'}))
    assert out.returncode == 0, out.stderr


@pytest.mark.parametrize("code,token", [
    ('if CommandLine.arguments.contains("-Bench") { run() }', "arguments"),
    ("let a = ProcessInfo.processInfo.arguments", "arguments"),
    ('let v = ProcessInfo.processInfo.environment["HOME"]', "environment"),
    ('let v = getenv("X")', "environment"),
    ('let on = env["ANTICHAT_NEW_HOOK"] == "1"', "ANTICHAT_NEW_HOOK"),
    ('let i = args.firstIndex(of: "-NewProbe")', "-NewProbe"),
    ('if UserDefaults.standard.bool(forKey: "SpikeUI") { spike() }', "SpikeUI"),
    ('let m = defaults.string(forKey: "ChatModel")', "ChatModel"),
])
def test_dev_read_outside_the_gate_fails(tmp_path, code, token):
    out = run(tree(tmp_path, {SRC: code + "\n"}))
    assert out.returncode == 1 and f"`{token}`" in out.stderr and "Thing.swift:1" in out.stderr
    # the same line inside the gate is fine
    assert run(tree(tmp_path, {SRC: GATED % code})).returncode == 0


def test_else_branch_and_negated_condition_are_not_gated(tmp_path):
    code = 'let v = env["ANTICHAT_NEW_HOOK"]'
    out = run(tree(tmp_path, {SRC: f"{g.GATE}\nlet a = 1\n#else\n{code}\n#endif\n"}))
    assert out.returncode == 1 and "Thing.swift:4" in out.stderr
    out = run(tree(tmp_path, {SRC: f"#if !DEBUG\n{code}\n#endif\n"}))
    assert out.returncode == 1 and "Thing.swift:2" in out.stderr
    assert run(tree(tmp_path, {SRC: f"#if !DEBUG\nlet a = 1\n#else\nlet b = 2\n#endif\n#if DEBUG\n{code}\n#endif\n"})).returncode == 0


def test_comments_are_ignored(tmp_path):
    out = run(tree(tmp_path, {SRC: '// `-Bench` reads CommandLine.arguments, "ANTICHAT_X"\nlet a = 1  // "-SpikeUI"\n'}))
    assert out.returncode == 0, out.stderr


def test_tests_and_tools_outside_the_app_are_not_scanned(tmp_path):
    out = run(tree(tmp_path, {"Packages/UI/Tests/AntiChatUITests/T.swift": "let a = CommandLine.arguments\n",
                              g.NOT_IN_THE_APP[0] + "main.swift": "let a = CommandLine.arguments\n"}))
    assert out.returncode == 0, out.stderr


@pytest.mark.parametrize("rel", ["App/AntiChat/BenchNew.swift", "App/AntiChat/NewProbe.swift", "App/AntiChat/DevModels.swift",
                                 "Packages/UI/Sources/AntiChatUI/Spike/SpikeChatView.swift",
                                 "Packages/UI/Sources/AntiChatUI/Artifacts/ArtifactsHarness.swift"])
def test_developer_file_must_be_wholly_gated(tmp_path, rel):
    body = "import Foundation\nenum X { static let a = 1 }"
    out = run(tree(tmp_path, {rel: body + "\n"}))
    assert out.returncode == 1 and "wholly inside" in out.stderr
    # the gate closes before the end of the file
    out = run(tree(tmp_path, {rel: f"// header\n{g.GATE}\nimport Foundation\n#endif\nenum X {{}}\n#if DEBUG\nlet b = 2\n#endif\n"}))
    assert out.returncode == 1 and "wholly inside" in out.stderr
    assert run(tree(tmp_path, {rel: "// header\n" + GATED % (body + "\n#if !DEBUG\nlet c = 3\n#endif")})).returncode == 0


def test_allow_list(tmp_path):
    code = 'let v = env["ANTICHAT_ENGINE_SERVICE"]\n'
    ok = f"{SRC}  ANTICHAT_ENGINE_SERVICE  # the helper's service name\n"
    assert run(tree(tmp_path, {SRC: code}, ok)).returncode == 0
    out = run(tree(tmp_path, {SRC: code}, f"{SRC}  ANTICHAT_ENGINE_SERVICE\n"))
    assert out.returncode == 1 and "no reason" in out.stderr
    out = run(tree(tmp_path, {SRC: "let a = 1\n"}, ok))
    assert out.returncode == 1 and "stale entry" in out.stderr
    out = run(tree(tmp_path, {SRC: code}, f"{SRC}  # only a path\n"))
    assert out.returncode == 1 and "expected" in out.stderr
    # an entry covers its own file and token only
    out = run(tree(tmp_path, {SRC: code, "App/AntiChat/Other.swift": code}, ok))
    assert out.returncode == 1 and "Other.swift:1" in out.stderr


@pytest.mark.parametrize("marker", g.MARKERS)
def test_marker_outside_the_gate_fails_even_when_allow_listed(tmp_path, marker):
    assert len(marker.encode()) > 15  # shorter Swift literals are stored inline: a byte search would never find them
    code = f'let m = "{marker}"\n'
    out = run(tree(tmp_path, {SRC: code}, f"{SRC}  {marker}  # no\n"))
    assert out.returncode == 1 and "developer-mode marker" in out.stderr
    assert run(tree(tmp_path, {SRC: GATED % code.strip()})).returncode == 0


def test_real_markers_exist_in_gated_source():
    """Each marker is really written by developer-only code (else the bundle check would be checking for nothing)."""
    texts = [f.read_text(encoding="utf-8", errors="replace") for f in g.shipping_swift(ROOT)]
    for m in g.MARKERS:
        assert any(m in g.code_part(line) for t in texts for _, line, dev in g.regions(t) if dev), m


def test_release_bundle_with_a_marker_fails(tmp_path):
    r = tree(tmp_path / "src", {SRC: "let a = 1\n"})
    clean = bundle(tmp_path / "a", "AntiChat", MACHO + b"\0code\0")
    assert run(r, "--app", str(clean)).returncode == 0
    for m in g.MARKERS:
        bad = bundle(tmp_path / ("b-" + m.strip("-")), "AntiChat", MACHO + b"\0" + m.encode() + b"\0")
        out = run(r, "--app", str(bad), "--app-only")
        assert out.returncode == 1 and m in out.stderr
    # a resource that is not an executable is not compiled code
    text = bundle(tmp_path / "c", "notes.txt", g.MARKERS[0].encode())
    assert run(r, "--app", str(text), "--app-only").returncode == 0
    assert run(r, "--app", str(tmp_path / "missing.app"), "--app-only").returncode == 1


def test_source_failure_is_reported_with_app_unless_app_only(tmp_path):
    r = tree(tmp_path / "src", {SRC: "let a = CommandLine.arguments\n"})
    clean = bundle(tmp_path / "a", "AntiChat", MACHO + b"\0code\0")
    assert run(r, "--app", str(clean)).returncode == 1
    assert run(r, "--app", str(clean), "--app-only").returncode == 0
