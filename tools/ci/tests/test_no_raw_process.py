"""M7.T13: tools/ci/no-raw-process.py fails on a seeded raw spawn, an unjustified or stale allow-list line, and passes
the real tree. Run: tools/.venv/bin/python -I -m pytest tools/ci/tests/test_no_raw_process.py -q"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

CI = Path(__file__).resolve().parents[1]
ROOT = CI.parents[1]
spec = importlib.util.spec_from_file_location("no_raw_process", CI / "no-raw-process.py")
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

LAUNCHER = "Packages/Platform/Sources/AntiChatPlatform/ProcessLauncher.swift"


def tree(tmp: Path, files: dict[str, str], allow: str = "") -> Path:
    for rel, text in {LAUNCHER: "let r = try await Subprocess.run(x)\n", **files}.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    (tmp / "tools/ci").mkdir(parents=True, exist_ok=True)
    (tmp / "tools/ci/no-raw-process-allow.txt").write_text(allow)
    return tmp


def test_real_tree_passes():
    assert lint.main(["x", str(ROOT)]) == 0


@pytest.mark.parametrize("code", [
    "let p = Process()\n", "posix_spawn(&pid, path, nil, nil, argv, environ)\n",
    "_ = try await Subprocess.run(.name(\"sh\"), output: .discarded)\n", "let t = NSTask()\n",
])
def test_seeded_spawn_fails(tmp_path, code):
    root = tree(tmp_path, {"Packages/Tools/Sources/AntiChatTools/Skills/Runner.swift": code})
    assert lint.main(["x", str(root)]) == 1


def test_comment_and_launcher_pass(tmp_path):
    root = tree(tmp_path, {"Packages/Tools/Sources/AntiChatTools/A.swift": "// never Process() here\nlet byProcess = 1\n"})
    assert lint.main(["x", str(root)]) == 0


def test_allow_list_needs_reason_and_no_stale(tmp_path):
    f = {"Packages/Platform/Sources/AntiChatPlatform/X.swift": "let p = Process()\n"}
    assert lint.main(["x", str(tree(tmp_path / "a", f, "Packages/Platform/Sources/AntiChatPlatform/X.swift  # ditto\n"))]) == 0
    assert lint.main(["x", str(tree(tmp_path / "b", f, "Packages/Platform/Sources/AntiChatPlatform/X.swift\n"))]) == 1
    assert lint.main(["x", str(tree(tmp_path / "c", {}, "Packages/Gone.swift  # old\n"))]) == 1
