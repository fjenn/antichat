#!/usr/bin/env python3
"""Play a fixture into a named Core Audio output device (M0.T05 step 3, blackhole mode).

The preferred V1 method plays the fixture into BlackHole 2ch v0.6.1 (needs P-ADMIN: `sudo installer -pkg
BlackHole2ch-0.6.1.pkg -target /` from the ExistentialAudio/BlackHole GitHub release), captures it in the
helper with VPIO on, and records the output on BlackHole channel 2.

This script checks the device first. When the driver is absent it exits 4 with
`not run: permission (BlackHole needs P-ADMIN)`, and the bench falls back to `--mode inject` ([IN-PIPELINE]),
as M0.md T05 step 3 says. With the driver present it checks the device name (`say -a ?`) and plays through
`afplay` to the default output, which the caller sets to BlackHole first. Not exercised in M0 (no admin);
M3 vq-08 completes this path if admin becomes available.

Usage: python3 -I tools/audio/play-to-device.py BlackHole FILE
"""
from __future__ import annotations

import os
import subprocess
import sys

HAL = "/Library/Audio/Plug-Ins/HAL"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    device, path = sys.argv[1], sys.argv[2]
    present = any(device.lower() in n.lower() for n in os.listdir(HAL)) if os.path.isdir(HAL) else False
    if not present:
        print(f"not run: permission (BlackHole needs P-ADMIN; no {device} driver in {HAL})")
        return 4
    devices = subprocess.run(["/usr/bin/say", "-a", "?"], capture_output=True, text=True).stdout
    if device.lower() not in devices.lower():
        print(f"{device} driver installed but no output device of that name: {devices.strip()}")
        return 5
    # `afplay` has no device option; the caller sets BlackHole as the default output before this call.
    return subprocess.run(["/usr/bin/afplay", path]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
