#!/usr/bin/env python3
"""Just-in-time permission lint (M8.T14 step 5; R-109, AT-109). Run with `python3 -I` (stdlib only).

PermissionCoordinator is the only place AntiChat asks macOS for a privacy permission. Fails (`file:line: …`) when
  1. a system request API — `AVCaptureDevice.requestAccess`, `AXIsProcessTrustedWithOptions`,
     `CGRequestScreenCaptureAccess`, `CGRequestListenEventAccess`, `requestAuthorization(options:`,
     `requestWhenInUseAuthorization`, `requestAlwaysAuthorization`, `requestRecordPermission` — appears in first-party
     Swift (App/, Packages/*/Sources) outside `Packages/Platform/Sources/AntiChatPlatform/Permissions/PermissionCoordinator.swift`;
  2. it appears in vendored code (Vendor/) outside the vendored Osaurus `SystemPermissionService.swift` and
     `Voice/KeyboardSimulationService.swift` (the global-dictation file vendored for M11, D-026), or first-party code
     reaches those vendored request paths (`requestAccessibilityPermission`, `SystemPermissionService`,
     `KeyboardSimulationService`) — they must stay unreachable in v1;
  3. onboarding (Packages/UI/Sources/AntiChatUI/Onboarding/) names a permission requester at all
     (`PermissionCoordinator`, `PermissionCenter`, `LocationPermission`, `requestAfterExplainer`, `ensure(`):
     onboarding never asks (R-109 AC1).
Comment lines are ignored. Tests (`/Tests/`, App/UITests, App/IntegrationTests) are out of scope.

  --root <dir>   repository root (tests)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

APIS = re.compile(r"AVCaptureDevice\.requestAccess|AXIsProcessTrustedWithOptions|CGRequestScreenCaptureAccess|"
                  r"CGRequestListenEventAccess|requestAuthorization\(options:|requestWhenInUseAuthorization|"
                  r"requestAlwaysAuthorization|requestRecordPermission")
COORDINATOR = "Packages/Platform/Sources/AntiChatPlatform/Permissions/PermissionCoordinator.swift"
VENDORED_OK = ("/Services/SystemPermissionService.swift", "/Services/Voice/KeyboardSimulationService.swift")
VENDORED_PATHS = re.compile(r"\brequestAccessibilityPermission\b|\bSystemPermissionService\b|\bKeyboardSimulationService\b")
ONBOARDING = "Packages/UI/Sources/AntiChatUI/Onboarding/"
ONBOARDING_BAD = re.compile(r"\bPermissionCoordinator\b|\bPermissionCenter\b|\bLocationPermission\b|requestAfterExplainer|\bensure\(")


def code_lines(path: Path):
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        s = line.strip()
        if s.startswith("//") or s.startswith("///") or s.startswith("*"):
            continue
        yield i, line.split("//")[0] if "//" in line and '"' not in line.split("//")[0] else line


def first_party(root: Path):
    for base in ("App", "Packages"):
        for p in sorted((root / base).rglob("*.swift")):
            rel = p.relative_to(root).as_posix()
            if "/.build/" in rel or "/Tests/" in rel or rel.startswith("App/UITests/") or rel.startswith("App/IntegrationTests/"):
                continue
            if rel.startswith("Packages/") and "/Sources/" not in rel:
                continue
            yield rel, p


def check(root: Path) -> tuple[list[str], dict]:
    errors: list[str] = []
    stats = {"first_party_files": 0, "coordinator_calls": 0, "vendored_calls": 0}
    for rel, p in first_party(root):
        stats["first_party_files"] += 1
        for i, line in code_lines(p):
            if APIS.search(line):
                if rel == COORDINATOR:
                    stats["coordinator_calls"] += 1
                else:
                    errors.append(f"{rel}:{i}: system permission request outside PermissionCoordinator: {line.strip()}")
            if VENDORED_PATHS.search(line):
                errors.append(f"{rel}:{i}: first-party code reaches a vendored permission request path: {line.strip()}")
            if rel.startswith(ONBOARDING) and ONBOARDING_BAD.search(line):
                errors.append(f"{rel}:{i}: onboarding must not ask for permissions (R-109 AC1): {line.strip()}")
    vendor = root / "Vendor"
    if vendor.is_dir():
        for p in sorted(vendor.rglob("*.swift")):
            rel = p.relative_to(root).as_posix()
            if "/.upstream/" in rel or "/.build/" in rel:
                continue
            for i, line in code_lines(p):
                if APIS.search(line):
                    if rel.endswith(VENDORED_OK):
                        stats["vendored_calls"] += 1
                    else:
                        errors.append(f"{rel}:{i}: system permission request in vendored code outside the allowed files")
    return errors, stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    a = ap.parse_args()
    errors, stats = check(Path(a.root))
    for e in errors:
        print(f"error: {e}")
    print(f"permission-calls: {len(errors)} violation(s) {stats}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
