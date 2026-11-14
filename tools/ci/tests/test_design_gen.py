"""Self-tests for the M1.T03 design generators (tools/design/gen-tokens.py, gen-xcstrings.py)."""
from __future__ import annotations

import importlib.util

import pytest
from conftest import ROOT, load


def load_design(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "tools/design" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gx = load_design("gen-xcstrings")
gt = load_design("gen-tokens")
cs = load("copy-sync")


def test_xcstrings_keys_equal_copy_sync_keys():
    entries = gx.parse(gx.DECK.read_text(encoding="utf-8"))
    assert set(entries) == set(cs.deck_keys(ROOT / cs.DECK))


def test_multi_key_rows_split_in_order():
    text = "| Key | String |\n|---|---|\n| `a.one` / `.two` / `a.three` | One / Two / Three |\n"
    e = gx.parse(text)
    assert {k: v for k, (v, _) in e.items()} == {"a.one": "One", "a.two": "Two", "a.three": "Three"}


def test_shared_string_for_multi_key_row():
    e = gx.parse("| Code | Where | String | Actions |\n|---|---|---|---|\n| `r.a` / `r.b` | x | Busy. | — |\n")
    assert e["r.a"][0] == e["r.b"][0] == "Busy."


def test_count_mismatch_fails():
    with pytest.raises(gx.GenError):
        gx.parse("| Key | String |\n|---|---|\n| `a.one` / `.two` / `.three` | One / Two |\n")


def test_duplicate_key_fails():
    with pytest.raises(gx.GenError):
        gx.parse("| Key | String |\n|---|---|\n| `a.one` | One |\n| `a.one` | Uno |\n")


def test_generated_files_are_current():
    files = gt.build()
    stale = [p for p, c in files.items() if not p.exists() or p.read_text(encoding="utf-8") != c]
    assert stale == []
    entries = gx.parse(gx.DECK.read_text(encoding="utf-8"))
    assert gx.XCSTRINGS.read_text(encoding="utf-8") == gx.xcstrings(entries)
    assert gx.SWIFT.read_text(encoding="utf-8") == gx.swift(entries)


@pytest.mark.parametrize("cell,want", [
    ("`#0D0D0D`", "#0D0D0DFF"),
    ("`#0000000D` (5% black)", "#0000000D"),
    ("`#000000` at 35% over the full-colour art", "#00000059"),
    ("`#FFFFFF` + `shadow.1`", "#FFFFFFFF"),
    ("bg `#146C2E26`, fg `#0F5C27`", {"bg": "#146C2E26", "fg": "#0F5C27FF"}),
    ("`#9E3030`, label `#FFFFFF` (7.2:1)", {"": "#9E3030FF", "label": "#FFFFFFFF"}),
    ("`sys:keyboardFocusIndicatorColor`", {"sys": "keyboardFocusIndicatorColor"}),
    ("—", None),
])
def test_colour_cells(cell, want):
    assert gt.parse_value(cell) == want


def test_contrast_pair_with_unknown_token_fails():
    secs = {"7": ["| Foreground | Background | Min | Modes | Where |", "|---|---|---|---|---|",
                  "| `text.primary` | `no.such.token` | 4.5 | all | x |"]}
    with pytest.raises(gt.GenError):
        gt.pairs(secs, {"text.primary": {}})
