#!/usr/bin/env python3
"""Installer volume icon: the AntiChat app icon with a download badge (deterministic, no hand edits).

So the mounted installer never looks like the app itself, the DMG volume icon (tools/release/dmg/VolumeIcon.icns) is
the app icon's Default rendition with a dark round badge (white ring, white down-arrow into a tray) at the lower right.
Input: build/icon/AppIcon-Default.png (tools/design/make-app-icon.py renders it); otherwise rendered here with Icon
Composer's ictool from App/AntiChat/AppIcon.icon.
Run with the release venv (Pillow): build/release-venv/bin/python -I tools/design/make-installer-icon.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "App/AntiChat/AppIcon.icon"
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
MASTER = ROOT / "build/icon/AppIcon-Default.png"
OUTS = [ROOT / "tools/release/dmg/VolumeIcon.icns"]
INK = (28, 28, 34, 255)
WHITE = (255, 255, 255, 255)


def master() -> Image.Image:
    if not MASTER.exists():
        MASTER.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(ICTOOL), str(ICON), "--export-image", "--output-file", str(MASTER), "--platform", "macOS",
                        "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"], check=True)
    return Image.open(MASTER).convert("RGBA").resize((1024, 1024), Image.LANCZOS)


def badged() -> Image.Image:
    s = 4                                                   # supersample for smooth edges
    body = master().resize((824 * s, 824 * s), Image.LANCZOS)   # macOS icon grid: 824 body in a 1024 canvas
    big = Image.new("RGBA", (1024 * s, 1024 * s), (0, 0, 0, 0))
    big.alpha_composite(body, (100 * s, 100 * s))
    d = ImageDraw.Draw(big)
    cx, cy, r, ring = 790 * s, 790 * s, 176 * s, 18 * s
    d.ellipse([cx - r - ring, cy - r - ring, cx + r + ring, cy + r + ring], fill=WHITE)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=INK)
    w = 30 * s                                              # stroke width
    top, tip = cy - 98 * s, cy + 36 * s
    d.rectangle([cx - w // 2, top, cx + w // 2, tip - 36 * s], fill=WHITE)          # shaft
    d.polygon([(cx, tip + 8 * s), (cx - 68 * s, tip - 62 * s), (cx + 68 * s, tip - 62 * s)], fill=WHITE)  # head
    ty = cy + 88 * s                                        # tray
    d.rounded_rectangle([cx - 98 * s, ty - w // 2, cx + 98 * s, ty + w // 2], radius=w // 2, fill=WHITE)
    return big.resize((1024, 1024), Image.LANCZOS)


def write_icns(img: Image.Image, icns: Path, work: Path) -> None:
    iconset = work / (icns.stem + ".iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            img.resize((pt * scale, pt * scale), Image.LANCZOS).save(iconset / name)
    icns.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)


def main() -> int:
    img = badged()
    work = ROOT / "build/icon"
    work.mkdir(parents=True, exist_ok=True)
    img.save(work / "InstallerIcon.png")
    for out in OUTS:
        write_icns(img, out, work)
    print("make-installer-icon: " + ", ".join(str(o.relative_to(ROOT)) for o in OUTS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
