"""Negative self-tests for tools/ci/perfharness-guard.py (M9.T05): the perf-harness flag stays in build-perf.sh and in
`#if DEBUG || ANTICHAT_PERF_HARNESS` gates, and no release/try-out bundle carries the marker."""
import shutil
import subprocess
import sys

from conftest import CI, ROOT, load

g = load("perfharness-guard")
GATED = "Packages/Platform/Sources/AntiChatPlatform/Storage/DataPaths.swift"


def tree(tmp_path):
    for rel in (g.BUILD_PERF, g.FLAVOR, GATED, "Makefile", "project.yml", "tools/release/build-release.sh"):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    return tmp_path


def run(root, *args):
    return subprocess.run([sys.executable, "-I", str(CI / "perfharness-guard.py"), "--root", str(root), *args],
                          capture_output=True, text=True)


def edit(root, rel, old, new):
    p = root / rel
    s = p.read_text(encoding="utf-8")
    assert old in s, old
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


def bundle(tmp_path, binary):
    a = tmp_path / "rel/AntiChat.app/Contents/MacOS"
    a.mkdir(parents=True)
    (a / "AntiChat").write_bytes(binary)
    return a.parent.parent


def test_clean_tree_passes(tmp_path):
    out = run(tree(tmp_path))
    assert out.returncode == 0, out.stderr


def test_real_tree_passes():
    out = subprocess.run([sys.executable, "-I", str(CI / "perfharness-guard.py"), "--root", str(ROOT)],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr


def test_flag_in_release_script_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, "tools/release/build-release.sh", "conditions=()",
         "conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS')")
    out = run(r)
    assert out.returncode == 1 and "build-release.sh" in out.stderr


def test_flag_in_project_yml_fails(tmp_path):
    r = tree(tmp_path)
    p = r / "project.yml"
    p.write_text(p.read_text() + "\n        SWIFT_ACTIVE_COMPILATION_CONDITIONS: ANTICHAT_PERF_HARNESS\n")
    out = run(r)
    assert out.returncode == 1 and "project.yml" in out.stderr


def test_flag_in_makefile_recipe_fails(tmp_path):
    r = tree(tmp_path)
    p = r / "Makefile"
    p.write_text(p.read_text() + "\nleak:\n\txcodebuild SWIFT_ACTIVE_COMPILATION_CONDITIONS=ANTICHAT_PERF_HARNESS\n")
    out = run(r)
    assert out.returncode == 1 and "Makefile" in out.stderr


def test_second_flag_line_in_build_perf_fails(tmp_path):
    r = tree(tmp_path)
    p = r / g.BUILD_PERF
    p.write_text(p.read_text() + "\nOTHER_SWIFT_FLAGS=-DANTICHAT_PERF_HARNESS\n")
    out = run(r)
    assert out.returncode == 1 and "exactly" in out.stderr


def test_bench_builder_rules(tmp_path):
    """tools/bench.sh and the M0 gate scripts build the never-shipped bench app with the flag, into build/dd-bench."""
    r = tree(tmp_path)
    for rel in g.BENCH_BUILDERS:
        (r / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, r / rel)
        assert g.BENCH_CONDITION in (r / rel).read_text(), rel
    assert run(r).returncode == 0
    bench = r / g.BENCH_BUILDERS[0]
    orig = bench.read_text()
    bench.write_text(orig + "\nOTHER_SWIFT_FLAGS=-DANTICHAT_PERF_HARNESS\n")
    out = run(r)
    assert out.returncode == 1 and "bench.sh" in out.stderr
    bench.write_text(orig + "\ncp -R x build/release/AntiChat.app\n")
    out = run(r)
    assert out.returncode == 1 and "never archives or writes a release" in out.stderr
    bench.write_text(orig.replace("dd-bench", "dd-other"))
    out = run(r)
    assert out.returncode == 1 and "not into build/dd-bench" in out.stderr


def test_flag_in_another_tool_script_fails(tmp_path):
    r = tree(tmp_path)
    p = r / "tools/at/new-probe.sh"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("xcodebuild 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS' build\n")
    out = run(r)
    assert out.returncode == 1 and "new-probe.sh" in out.stderr


def test_ungated_swift_use_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, GATED, "#if DEBUG || ANTICHAT_PERF_HARNESS", "#if ANTICHAT_PERF_HARNESS")
    out = run(r)
    assert out.returncode == 1 and "DataPaths.swift" in out.stderr


def test_debug_or_perf_condition_in_the_safety_gate_fails(tmp_path):
    r = tree(tmp_path)
    rel = g.GATE_SOURCES[0]
    (r / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / rel, r / rel)
    assert run(r).returncode == 0
    edit(r, rel, "public actor MediaOutputGate {", "public actor MediaOutputGate {\n    #if DEBUG || ANTICHAT_PERF_HARNESS\n    static let skip = true\n    #endif")
    out = run(r)
    assert out.returncode == 1 and "D-006" in out.stderr


def test_release_bundle_with_marker_fails(tmp_path):
    r = tree(tmp_path)
    clean = bundle(tmp_path / "a", b"\0code\0")
    assert run(r, "--app", str(clean)).returncode == 0
    perf = bundle(tmp_path / "b", b"\0" + g.MARKER.encode() + b"\0")
    out = run(r, "--app", str(perf))
    assert out.returncode == 1 and "marker" in out.stderr
    # without --app the default release location is checked
    shutil.copytree(perf, r / "build/release/AntiChat.app")
    out = run(r)
    assert out.returncode == 1 and "build/release" in out.stderr
