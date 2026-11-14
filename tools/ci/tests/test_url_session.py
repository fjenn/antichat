from conftest import load, seeded

us = load("url-session-lint")
F = "Packages/Storage/Sources/AntiChatStorage/__selftest_urlsession.swift"


def test_clean_tree_passes(root):
    assert us.check(root) == []


def test_urlsession_outside_network_fails(root):
    with seeded({F: "import Foundation\nlet s = URLSession(configuration: .default)\n"}):
        errs = us.check(root)
    assert any(e.startswith(F) for e in errs), errs
