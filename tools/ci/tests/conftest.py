"""Negative self-tests for the M1.T02 audits (docs/prd/M1.md M1.T02 step 7).

Each test seeds a violation as a temporary untracked file in the real tree (the audits read
`git ls-files -co --exclude-standard`, so untracked files count), asserts the audit fails on exactly that
file, and always removes the file again. A positive control asserts the clean tree passes.
Run: tools/.venv/bin/python -I -m pytest tools/ci/tests -q
"""
from __future__ import annotations

import contextlib
import importlib.util
import sys
from pathlib import Path

import pytest

CI = Path(__file__).resolve().parents[1]
ROOT = CI.parents[1]
sys.path.insert(0, str(CI))


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), CI / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@contextlib.contextmanager
def seeded(files: dict[str, str]):
    made = []
    try:
        for rel, text in files.items():
            p = ROOT / rel
            assert not p.exists(), f"refusing to overwrite {rel}"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
            made.append(p)
        yield
    finally:
        for p in made:
            p.unlink(missing_ok=True)


@pytest.fixture
def root() -> Path:
    return ROOT
