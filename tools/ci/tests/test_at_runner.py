import json
import shutil
import subprocess

from conftest import ROOT


def test_runner_writes_result_and_propagates_exit():
    d = ROOT / "build/at/SELFTEST-RUNNER"
    shutil.rmtree(d, ignore_errors=True)
    try:
        p = subprocess.run([str(ROOT / "tools/at/run.sh"), "SELFTEST-RUNNER", "--", "bash", "-c", "echo hi; exit 3"],
                           capture_output=True, text=True)
        assert p.returncode == 3
        r = json.loads((d / "result.json").read_text())
        assert r["id"] == "SELFTEST-RUNNER" and r["exit"] == 3 and r["pass"] is False
        assert set(r) >= {"id", "date", "commit", "cmd", "exit", "pass"}
        assert "hi" in (ROOT / r["log"]).read_text()
        (d / "pending.txt").write_text("leg (4)\n")
        p = subprocess.run([str(ROOT / "tools/at/run.sh"), "SELFTEST-RUNNER", "--", "true"])
        r = json.loads((d / "result.json").read_text())
        assert p.returncode == 0 and r["pass"] is False and r["pending"] == ["leg (4)"]
    finally:
        shutil.rmtree(d, ignore_errors=True)
