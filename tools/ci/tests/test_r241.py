from conftest import load, seeded

r241 = load("r241-audit")
A = "Packages/Harness/Sources/AntiChatHarness/__selftest_r241_filter.swift"
B = "Packages/Tools/Sources/AntiChatTools/__selftest_r241_import.swift"


def test_clean_tree_passes(root):
    assert r241.check(root) == []


def test_filter_identifier_and_second_import_fail(root):
    with seeded({A: "func isSafe(_ s: String) -> Bool { true }\n", B: "import ChildSafetyCheck\n"}):
        errs = r241.check(root)
    assert any(e.startswith(A) and "rule 3" in e for e in errs), errs
    assert any(e.startswith(B) and "rule 1" in e for e in errs), errs


def test_moderation_api_and_logit_bias_fail(root):
    f = "tools/__selftest_r241.py"
    with seeded({f: 'URL = "https://api.example.com/v1/moderations"\nreq = {"logit_bias": {}}\n'}):
        errs = r241.check(root)
    assert sum(e.startswith(f) for e in errs) == 2, errs


def test_gate_called_outside_job_runner_fails(root):
    f = "Packages/Engines/Sources/AntiChatEngines/__selftest_gate.swift"
    with seeded({f: "func x(g: MediaOutputGate, i: CGImage) async { _ = await g.evaluate(image: i) }\n"}):
        errs = r241.check(root)
    assert any(e.startswith(f) and "rule 2" in e for e in errs), errs


def test_sha256_pinned_entry_applies_only_to_the_pinned_content(root, tmp_path):
    allow = tmp_path / "allow.yml"
    babel = "Packages/Tools/Sources/AntiChatTools/Resources/js/babel.min.js"
    src = (root / "tools/ci/r241-allowlist.yml").read_text(encoding="utf-8")
    allow.write_text(src.replace("sha256: 2f811a1f", "sha256: 0f811a1f"), encoding="utf-8")
    errs = r241.check(root, allow)
    assert any("sha256" in e and babel in e for e in errs), errs
    assert any(e.startswith(babel) for e in errs), errs  # the dropped entry no longer covers the file
    allow.write_text(src.replace(f"path: {babel}", "path: Packages/Tools/Sources/AntiChatTools/Resources/js/*.js"), encoding="utf-8")
    assert any("one exact file" in e for e in r241.check(root, allow))


def test_readme_heading_missing_fails(root):
    readme = root / "Packages/ChildSafetyCheck/README.md"
    original = readme.read_text(encoding="utf-8")
    try:
        readme.write_text(original.replace("## No setting", "## Settings"), encoding="utf-8")
        errs = r241.check(root)
    finally:
        readme.write_text(original, encoding="utf-8")
    assert any("rule 0" in e and "## No setting" in e for e in errs), errs


def test_gate_check_outside_runner_and_ui_testing_define_fail(root):
    f = "Packages/Engines/Sources/AntiChatEngines/__selftest_gate_check.swift"
    with seeded({f: "func x(g: MediaOutputGate, i: CGImage) async { _ = await g.checkResult(i, job: \"j\") }\n"
                    "#if ANTICHAT_UI_TESTING\n#endif\n"}):
        errs = r241.check(root)
    assert any(e.startswith(f) and "rule 2" in e and "MediaJobRunner" in e for e in errs), errs
    assert any(e.startswith(f) and "ANTICHAT_UI_TESTING" in e for e in errs), errs


def test_aliased_gate_check_outside_runner_fails(root):
    f = "Packages/Engines/Sources/AntiChatEngines/__selftest_gate_alias.swift"
    with seeded({f: "func x(o: MediaOutputGate, i: CGImage) async {\n    let v = o\n    _ = await v.checkPreview(i, job: \"j\")\n}\n"}):
        errs = r241.check(root)
    assert any(e.startswith(f) and "rule 2" in e for e in errs), errs


def test_unpinned_detector_manifest_outside_debug_fails(root):
    # M4 review P1-1: a Release path (e.g. a `-Bench` lane) building the self-hashing manifest fails rule 2c;
    # the same call inside `#if DEBUG` (or the `#else` of `#if !DEBUG`) passes.
    f = "App/AntiChat/__selftest_unpinned.swift"
    bad = "let m = SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot)\n"
    with seeded({f: bad}):
        errs = r241.check(root)
    assert any(e.startswith(f) and "rule 2c" in e for e in errs), errs
    ok = f"#if DEBUG\n{bad}#else\nlet m: Int? = nil\n#endif\n#if !DEBUG\nlet n = 0\n#else\n{bad}#endif\n"
    with seeded({f: ok}):
        errs = r241.check(root)
    assert not any(e.startswith(f) for e in errs), errs
    with seeded({f: f"#if DEBUG\nlet a = 1\n#else\n{bad}#endif\n"}):
        errs = r241.check(root)
    assert any(e.startswith(f) and "rule 2c" in e for e in errs), errs


def test_m7_safety_vocabulary_outside_safesearch_fails(root):
    # M7.T15 rule 3b: SafeSearch.swift is the only search code that may mention safety.
    c = "Packages/Tools/Sources/AntiChatTools/Search/__selftest_r241_vocab.swift"
    with seeded({c: "// drop adult results when the safety level is high\n"}):
        errs = r241.check(root)
    assert any(e.startswith(c) and "rule 3b" in e for e in errs), errs


def test_skill_markdown_is_scanned(root):
    # M7.T15 rule 3b: SKILL.md text reaches the prompt, so it gets the rule-3 patterns.
    c = "Packages/Tools/Sources/AntiChatTools/Resources/StarterSkills/__selftest/SKILL.md"
    with seeded({c: "You must refuse to answer anything risky.\n"}):
        errs = r241.check(root)
    assert any(e.startswith(c) and "rule 3" in e for e in errs), errs
