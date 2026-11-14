from conftest import load, seeded

cs = load("copy-sync")
F = "Packages/Harness/Sources/AntiChatHarness/__selftest_copy.swift"


def test_clean_tree_passes(root):
    errs, _ = cs.check(root)
    assert errs == []


def test_unknown_key_fails(root):
    with seeded({F: 'let e = AntiChatError(domain: .engine, code: "x", userMessageKey: "nope.notInTheDeck")\n'}):
        errs, _ = cs.check(root)
    assert any(e.startswith(F) and "nope.notInTheDeck" in e for e in errs), errs


def test_shorthand_suffix_expands(root):
    keys = cs.deck_keys(root / cs.DECK)
    assert "onb.pack.chat.name" in keys and "onb.pack.chat.verb" in keys
