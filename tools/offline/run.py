#!/usr/bin/env python3
"""Offline / privacy runner (`make test-offline [FILTER=<case>]`, test-strategy §7). Run with `python3 -I`.

Cases land with their tasks:
  incognito-disk-diff   M1.T20 AT-NFR-PR3 (§7.5): journey 8 on the real XPC helper with `chat-0.8b` (`min` models),
                        `-OfflineOnly YES`, inside tools/ci/disk-diff.py (zero new/changed files under the data
                        folder, fixture-phrase grep = 0). GPU job: runs under `lockf /tmp/antichat-gpu.lock`.
Each case is executed through tools/at/run.sh so its log and result.json land in build/at/<AT-ID>/.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CASES: dict[str, tuple[str, list[str]]] = {
    # M2.T03: AT-209 AC1 (§7.1) — the app under deny-outbound with Offline only; journeys attach (pending Q-015).
    "offline-only": ("AT-209", ["tools/offline/run-offline.sh", "20"]),
    # §7.2: no route (-FakeNetwork none) under the same sandbox; OfflineNoRouteTests UI assertions pending Q-015.
    "no-route": ("AT-NFR-PR1", ["tools/offline/run-offline.sh", "20", "--", "-FakeNetwork", "none"]),
    # §7.3: 30-minute capture (MINUTES=… shortens it); pcap only with passwordless sudo.
    "capture": ("AT-NFR-PR1", ["tools/offline/capture-30min.sh"]),
    # M4.T11: SandboxedWebPreview on network-probe.html inside the artifacts host, under deny-outbound.
    "SandboxedWebPreview": ("M4.T11", ["tools/offline/web-preview.sh"]),
    # M3.T03 AT-050 AC2: dictation (helper, ScriptedVoice, real Parakeet) under deny-outbound with Offline only on.
    # (fixtures from $ANTICHAT_FIXTURES, else ./fixtures)
    "dictation": ("AT-050", ["tools/offline/run-offline.sh", "60", "--", "-Bench", "dictation", "--runs", "3",
                             "--raw", "build/at/AT-050/offline-dictation.jsonl"]),
    "incognito-disk-diff": ("AT-NFR-PR3", ["lockf", "/tmp/antichat-gpu.lock", "tools/at/t20-probe.sh", "real"]),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", help="one case name (default: all)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for name, (at, cmd) in CASES.items():
            print(f"{name}\t{at}\t{' '.join(cmd)}")
        return 0
    if a.case == "incognito":  # M2.T03: STEP=incognito = test-strategy §7.5 (M1's AT-090 disk-diff case)
        a.case = "incognito-disk-diff"
    names = [a.case] if a.case else list(CASES)
    unknown = [n for n in names if n not in CASES]
    if unknown:
        print(f"test-offline: unknown case(s) {unknown}; known: {sorted(CASES)}", file=sys.stderr)
        return 64
    failed = []
    for name in names:
        at, cmd = CASES[name]
        print(f"== {name} ({at})", flush=True)
        if subprocess.call(["tools/at/run.sh", at, "--", *cmd], cwd=ROOT) != 0:
            failed.append(name)
    print("test-offline:", "all passed" if not failed else f"failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
