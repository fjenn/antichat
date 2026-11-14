#!/usr/bin/env python3
"""CR-P-10 check (M1.T03): retrain the tiny-MLX tokenizer from its frozen corpus and compare tokenizer.json with
the stub-models lock. Exit 0 when the sha256 matches.

Usage: tools/.venv/bin/python -I tools/fixtures/check-tiny-mlx-tokenizer.py [--fixtures DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    a = ap.parse_args()
    spec = importlib.util.spec_from_file_location("make_tiny_mlx", HERE / "make-tiny-mlx.py")
    mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk)
    tok = mk.train_tokenizer(a.fixtures)
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "tokenizer.json"
        tok.save(str(p), pretty=False)
        got = hashlib.sha256(p.read_bytes()).hexdigest()
    want = json.loads((Path(a.fixtures) / "stub-models.lock.json").read_text())["files"]["tiny-mlx-llm/tokenizer.json"]["sha256"]
    print(f"corpus   {Path(mk.CORPUS_DECK).relative_to(ROOT)}")
    print(f"got      {got}")
    print(f"lock     {want}")
    print("tokenizer reproducible" if got == want else "MISMATCH")
    return 0 if got == want else 1


if __name__ == "__main__":
    sys.exit(main())
