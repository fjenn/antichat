#!/usr/bin/env python3
"""One bundle id ↔ one signing identity in the File tools test tooling (M6.T19; run with `python3 -I`).

macOS ties an App Sandbox container to the code identity that created it. Launching the File tools services under
the same bundle id with another signature (Debug/Xcode ad-hoc vs tools/release/sign.sh vs Developer ID) makes
secinitd show the owner "… differs from previously opened versions … access data" and blocks every sandboxed launch
until it is answered (2026-11-08). The dev identity owns the shipped ids (app.antichat.AntiChat[.FileTools[.Net]]);
everything else must use its own ids. A-M6-T21a (a): the shipped ids are the slot ids
app.antichat.AntiChat.FileTools[.Net].slot<k>, so every slot is one more id to keep. Checks, each failing with `file: …`:
  1. tools/at/ft-release-probe.sh derives PROBE_ID from the signing mode (relprobe-$MODE), rewrites the
     CFBundleIdentifier of the probe host app AND every slot service (…FileTools[.Net].slot<k>), keeps the
     per-identity registry for all of them, signs only the probe host (never "$APP") and never executes anything
     inside "$APP";
  2. tools/at/ft-release-probe/main.swift reaches the services only through FT_SERVICE_PREFIX (it must contain
     ".relprobe-"): its own FileToolsSlots(prefix: servicePrefix) leaser, never FileToolsSlots.shared, never a
     FileToolsClient(network:) without that leaser, never a literal shipped id or FileToolsProtocol.servicePrefix;
  3. every XCTestCase in App/IntegrationTests/FileTools/ calls FileToolsIT.requireDevBuild() in setUp (a Release
     test build would launch the shipped ids with another signature);
  4. no other script under tools/ re-signs a bundle with sign.sh/codesign and then launches FileTools services —
     except the listed probe-host runners (PROBE_HOSTS: tools/visual/vq-05-release.sh, the AT-VQ-M4 Release leg),
     which must keep the probe's own rules: a relprobe id for the host app AND both services, the registry, sign.sh
     only on "$HOST", nothing executed inside "$APP".
`--root DIR` checks another tree (self-tests).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PROBE_HOSTS = ["tools/visual/vq-05-release.sh"]


def host_rules(rel: str, s: str) -> list[str]:
    """Rule 4's exception: a probe-host runner launches only a relprobe-id copy it signed itself, recorded once."""
    bad: list[str] = []
    if not re.search(r'PROBE_ID="app\.antichat\.AntiChat\.relprobe-[a-z$A-Z]+"', s):
        bad.append(f"{rel}: PROBE_ID must be a relprobe id")
    if not re.search(r'Set :CFBundleIdentifier \$PROBE_ID"? "\$HOST/Contents/Info.plist"', s):
        bad.append(f"{rel}: the probe host app must get its own CFBundleIdentifier")
    if not re.search(r'Set :CFBundleIdentifier \$PROBE_ID\.FileTools[^\n]*\n?[^\n]*"\$HOST/Contents/XPCServices/AntiChatFileTools\$v\.xpc', s):
        bad.append(f"{rel}: both File tools services must get their own CFBundleIdentifier")
    if "signing-identities.tsv" not in s:
        bad.append(f"{rel}: the one-id-one-identity registry is missing")
    for m in re.finditer(r'sign\.sh"?[^\n]*--app "?\$([A-Z_]+)', s):
        if m.group(1) != "HOST":
            bad.append(f"{rel}: sign.sh may only sign the probe host, not ${m.group(1)}")
    if re.search(r'^\s*"?\$APP/Contents/(MacOS|XPCServices)/[^"\n]*"?\s', s, re.M) or re.search(r'open [^\n]*"\$APP"', s):
        bad.append(f"{rel}: launches the shipped build")
    return bad


def check(root: Path) -> list[str]:
    bad: list[str] = []
    probe = root / "tools/at/ft-release-probe.sh"
    s = probe.read_text() if probe.exists() else ""
    rel = "tools/at/ft-release-probe.sh"
    if not re.search(r'PROBE_ID="[^"]*relprobe-\$MODE"', s):
        bad.append(f"{rel}: PROBE_ID must be derived from the signing mode (relprobe-$MODE)")
    if not re.search(r'Set :CFBundleIdentifier \$PROBE_ID"? "\$HOST/Contents/Info.plist"', s):
        bad.append(f"{rel}: the probe host app must get its own CFBundleIdentifier")
    if not re.search(r'sid="\$PROBE_ID\.FileTools\$\{v:\+\.\$v\}\.slot\$k"', s) or \
            not re.search(r'Set :CFBundleIdentifier \$sid" "\$HOST/Contents/XPCServices/AntiChatFileTools\$\{v\}Slot\$k\.xpc', s):
        bad.append(f"{rel}: every File tools slot service must get its own CFBundleIdentifier")
    if not re.search(r'for b in "\$HOST" "\$\{SLOT_BUNDLES\[@\]', s):
        bad.append(f"{rel}: the identity registry must cover every slot service")
    if "signing-identities.tsv" not in s:
        bad.append(f"{rel}: the one-id-one-identity registry is missing")
    for m in re.finditer(r'sign\.sh"?[^\n]*--app "?\$([A-Z_]+)', s):
        if m.group(1) != "HOST":
            bad.append(f"{rel}: sign.sh may only sign the probe host, not ${m.group(1)}")
    if re.search(r'codesign\s+(--force|-f)[^\n]*"\$APP', s):
        bad.append(f"{rel}: re-signs the shipped build")
    if re.search(r'^\s*"?\$APP/Contents/(MacOS|XPCServices)/[^"\n]*"?\s', s, re.M):
        bad.append(f"{rel}: executes something inside the shipped build")
    main = root / "tools/at/ft-release-probe/main.swift"
    m = main.read_text() if main.exists() else ""
    if "FT_SERVICE_PREFIX" not in m or '".relprobe-"' not in m:
        bad.append("tools/at/ft-release-probe/main.swift: must require FT_SERVICE_PREFIX with .relprobe-")
    if (re.search(r"FileToolsClient\(network:(?![^)\n]*slots: probeSlots)", m) or "FileToolsSlots.shared" in m
            or re.search(r"FileToolsProtocol\.(serviceName|netServiceName|servicePrefix)", m) or "app.antichat.AntiChat.FileTools" in m
            or not re.search(r"FileToolsSlots\(capacity: [^)\n]*prefix: servicePrefix\)", m)):
        bad.append("tools/at/ft-release-probe/main.swift: connects to the shipped service ids")
    for f in sorted((root / "App/IntegrationTests/FileTools").glob("*.swift")):
        t = f.read_text()
        for cls in re.finditer(r"final class (\w+): XCTestCase \{\n(.{0,200})", t, re.S):
            if "requireDevBuild()" not in cls.group(2):
                bad.append(f"{f.relative_to(root)}: {cls.group(1)} must start with FileToolsIT.requireDevBuild()")
    for f in sorted((root / "tools").rglob("*.sh")):
        if f == probe or ".venv" in f.parts or f.parent == root / "tools/release":  # the signer itself launches nothing
            continue
        t = f.read_text(errors="replace")
        if str(f.relative_to(root)) in PROBE_HOSTS:
            bad.extend(host_rules(str(f.relative_to(root)), t))
            continue
        if ("release/sign.sh" in t or re.search(r"codesign\s+(--force|-f)", t)) and re.search(r"AntiChatFileTools|FileToolsClient", t):
            bad.append(f"{f.relative_to(root)}: re-signs and touches File tools services outside ft-release-probe.sh")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    root = Path(ap.parse_args().root)
    bad = check(root)
    for b in bad:
        print(b)
    print(f"signing-identity-ids: {'ok' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
