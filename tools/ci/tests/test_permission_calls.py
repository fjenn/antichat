"""Negative self-tests for tools/ci/permission-calls.py (M8.T14, AT-109): a seeded request outside
PermissionCoordinator, a first-party call into a vendored request path and an onboarding reference each fail."""
from conftest import ROOT, load

pc = load("permission-calls")


def write(root, rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def test_clean_tree_passes():
    errs, stats = pc.check(ROOT)
    assert errs == [], errs
    assert stats["coordinator_calls"] >= 6


def test_request_outside_coordinator_fails(tmp_path):
    write(tmp_path, pc.COORDINATOR, "let x = CGRequestScreenCaptureAccess()\n")
    write(tmp_path, "Packages/UI/Sources/AntiChatUI/Voice/Mic.swift",
          "func ask() async { _ = await AVCaptureDevice.requestAccess(for: .audio) }\n")
    errs, stats = pc.check(tmp_path)
    assert stats["coordinator_calls"] == 1
    assert len(errs) == 1 and "Mic.swift:1" in errs[0], errs


def test_comment_is_ignored(tmp_path):
    write(tmp_path, "App/AntiChat/Notes.swift", "// requestWhenInUseAuthorization is only called by the coordinator\n")
    assert pc.check(tmp_path)[0] == []


def test_vendored_path_from_first_party_fails(tmp_path):
    write(tmp_path, "Packages/UI/Sources/AntiChatUI/X.swift", "KeyboardSimulationService.shared.requestAccessibilityPermission()\n")
    errs, _ = pc.check(tmp_path)
    assert any("vendored permission request path" in e for e in errs), errs


def test_vendored_request_outside_allowed_files_fails(tmp_path):
    write(tmp_path, "Vendor/osaurus@1/Packages/OsaurusCore/Services/SystemPermissionService.swift",
          "_ = AXIsProcessTrustedWithOptions(o)\n")
    write(tmp_path, "Vendor/osaurus@1/Packages/OsaurusCore/Services/Other.swift", "_ = CGRequestListenEventAccess()\n")
    errs, stats = pc.check(tmp_path)
    assert stats["vendored_calls"] == 1
    assert len(errs) == 1 and "Other.swift" in errs[0], errs


def test_onboarding_reference_fails(tmp_path):
    write(tmp_path, pc.ONBOARDING + "Step.swift", "Task { await PermissionCenter.shared.request(.microphone) }\n")
    errs, _ = pc.check(tmp_path)
    assert any("onboarding must not ask" in e for e in errs), errs
