"""Negative self-tests for tools/ci/settings-map-check.py (M1.T22 step 7): a copy of Keys.swift and
settings-map.md in a temp root, one seeded drift per test."""
import shutil

from conftest import ROOT, load

sm = load("settings-map-check")


def tree(tmp_path):
    for rel in (sm.KEYS, sm.MAP):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    return tmp_path


def edit(root, rel, old, new):
    p = root / rel
    s = p.read_text(encoding="utf-8")
    assert old in s, old
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


def test_clean_tree_passes(root):
    errs, n = sm.check(root)
    assert errs == [] and n >= 13


def test_swift_default_drift_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, sm.KEYS, 'Key<Bool>("menuBarItem", default: true', 'Key<Bool>("menuBarItem", default: false')
    errs, _ = sm.check(r)
    assert any("menuBarItem default false" in e for e in errs), errs


def test_map_default_drift_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, sm.MAP, "| Auto-archive inactive chats | Never |", "| Auto-archive inactive chats | 30 days |")
    errs, _ = sm.check(r)
    assert any("autoArchiveDays" in e and "30 days" in e for e in errs), errs


def test_missing_annotation_fails(tmp_path):
    r = tree(tmp_path)
    edit(r, sm.KEYS, '    // settings-map: §1 "Plain-text composer" = "Off" ↔ false\n', "")
    errs, _ = sm.check(r)
    assert any("plainTextComposer has no `// settings-map:` annotation" in e for e in errs), errs
    assert any("'Plain-text composer' (M1, P0) has no key" in e for e in errs), errs
