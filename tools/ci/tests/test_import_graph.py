from conftest import load, seeded

ig = load("import-graph")
F = "Packages/UI/Sources/AntiChatUI/__selftest_import_graph.swift"


def test_clean_tree_passes(root):
    assert ig.check(root) == []


def test_ui_importing_engines_fails(root):
    with seeded({F: "import AntiChatEngines\n"}):
        errs = ig.check(root)
    assert any(e.startswith(F) and "AntiChatEngines" in e for e in errs), errs


def test_importing_ui_outside_app_fails(root):
    f = "Packages/Harness/Sources/AntiChatHarness/__selftest_ui_import.swift"
    with seeded({f: "import AntiChatUI\n"}):
        errs = ig.check(root)
    assert any(e.startswith(f) for e in errs), errs


def test_closure_is_transitive():
    assert "AntiChatStorage" in ig.closure("AntiChatUI")
    assert "AntiChatEngines" not in ig.closure("AntiChatUI")
