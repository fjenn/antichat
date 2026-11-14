"""Negative self-tests for tools/ci/no-retyped-budgets.py (M7.T14 step 1): a temp git repo holding a copy of
tier-budgets.json and one Swift file; a retyped `section.key: value` tuple fails, an opted-out line passes."""
import shutil
import subprocess
import sys

from conftest import ROOT

SCRIPT = ROOT / "tools/ci/no-retyped-budgets.py"
BUDGETS = "Packages/Harness/Resources/tier-budgets.json"


def repo(tmp_path, swift):
    (tmp_path / BUDGETS).parent.mkdir(parents=True)
    shutil.copy(ROOT / BUDGETS, tmp_path / BUDGETS)
    f = tmp_path / "Packages/Harness/Sources/X.swift"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(swift, encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "add", "-A"], check=True)
    return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(tmp_path)], capture_output=True, text=True)


def test_clean_tree_passes():
    r = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout


def test_retyped_dict_literal_fails(tmp_path):
    r = repo(tmp_path, 'let maxPerStep = ["T0": 3, "T1": 5]\n')
    assert r.returncode == 1 and "tools.max_per_step" in r.stdout, r.stdout


def test_retyped_subscript_fails(tmp_path):
    r = repo(tmp_path, '#expect(budgets.tools?.schemaTokenCap["T2"] == 2500)\n')
    assert r.returncode == 1 and "tools.schema_token_cap" in r.stdout, r.stdout


def test_opt_out_and_other_numbers_pass(tmp_path):
    r = repo(tmp_path, 'let maxPerStep = ["T0": 3]  // budget-ok: synthetic\nlet maxPerStep2 = ["T0": 99]\n')
    assert r.returncode == 0, r.stdout
