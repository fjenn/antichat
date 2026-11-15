#!/usr/bin/env python3
"""AntiChat app icon source (M10, tokens.md "App icon"; deterministic, no hand edits).

Writes App/AntiChat/AppIcon.icon, an Icon Composer document (macOS 26 layered icon: Default, Dark, Tinted and
Clear renditions come from the layers); then tools/design/make-installer-icon.py badges the Default rendition into
the DMG volume and installer icons:
  Assets/background.png  1024×1024 crop of the owner's artwork (docs/research/02-target/inputs/onboarding-reference/
                         onboarding-dreamworld-background.png, Git LFS; the shells + winding path), softened;
  Assets/mark.svg        the AntiChat mark, original: a speech bubble whose inside is the art's winding path,
                         white on glass (no third-party marks or type);
  icon.json              background group (no glass) under the mark group (glass, neutral shadow).
Then renders previews with Icon Composer's ictool (if Xcode has it) into build/icon/.
Run with the release venv (Pillow): build/release-venv/bin/python -I tools/design/make-app-icon.py
"""
from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "docs/research/02-target/inputs/onboarding-reference/onboarding-dreamworld-background.png"
ICON = ROOT / "App/AntiChat/AppIcon.icon"
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")

# The mark in a 1024 canvas: a bubble (rounded body + tail at lower left) with the winding path cut through it.
MARK_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <mask id="cut">
      <rect width="1024" height="1024" fill="white"/>
      <!-- the winding path from the artwork, carved through the bubble -->
      <path d="M 300 590 C 380 640, 430 520, 512 540 C 594 560, 620 430, 724 404"
            fill="none" stroke="black" stroke-width="50" stroke-linecap="round" stroke-linejoin="round"/>
    </mask>
  </defs>
  <path mask="url(#cut)" fill="#FFFFFF"
        d="M 512 196 C 700 196 836 322 836 488 C 836 654 700 780 512 780 C 470 780 430 774 393 762
           L 268 828 C 252 836 236 822 242 806 L 278 712 C 220 657 188 578 188 488 C 188 322 324 196 512 196 Z"/>
</svg>
"""

ICON_JSON = {
    "fill": {"automatic-gradient": "srgb:0.93725,0.84706,0.80000,1.00000"},
    "groups": [
        {
            "name": "Mark",
            "layers": [{"name": "mark", "image-name": "mark.svg", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.35},
        },
        {
            "name": "Background",
            "layers": [{"name": "background", "image-name": "background.png", "glass": False}],
            "shadow": {"kind": "none", "opacity": 0},
            "translucency": {"enabled": False, "value": 0},
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}


def load_art() -> Image.Image:
    data = ART.read_bytes()
    if data.startswith(b"version https://git-lfs"):
        data = subprocess.run(["git", "-C", str(ROOT), "lfs", "smudge"], input=data, capture_output=True,
                              check=True).stdout
    return Image.open(io.BytesIO(data)).convert("RGB")


def background() -> Image.Image:
    art = load_art()
    side = art.height                                   # square crop on the right: shells + path
    left = art.width - side
    img = art.crop((left, 0, left + side, side)).resize((1024, 1024), Image.LANCZOS)
    img = ImageEnhance.Color(img).enhance(0.85)
    img = img.filter(ImageFilter.GaussianBlur(6))       # an icon background, not a photo: soften detail
    return Image.blend(img, Image.new("RGB", img.size, (255, 236, 228)), 0.18)


def render(kind: str, out: Path, size: int = 1024) -> bool:
    if not ICTOOL.exists():
        return False
    r = subprocess.run([str(ICTOOL), str(ICON), "--export-image", "--output-file", str(out), "--platform", "macOS",
                        "--rendition", kind, "--width", str(size), "--height", str(size), "--scale", "1"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ictool {kind}: {r.stderr.strip() or r.stdout.strip()}", file=sys.stderr)
    return r.returncode == 0


def main() -> int:
    if ICON.exists():
        shutil.rmtree(ICON)
    (ICON / "Assets").mkdir(parents=True)
    background().save(ICON / "Assets/background.png", optimize=True)
    (ICON / "Assets/mark.svg").write_text(MARK_SVG)
    (ICON / "icon.json").write_text(json.dumps(ICON_JSON, indent=2, sort_keys=True) + "\n")
    out = ROOT / "build/icon"
    out.mkdir(parents=True, exist_ok=True)
    done = [k for k in ("Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark")
            if render(k, out / f"AppIcon-{k}.png")]
    if "Default" in done:
        subprocess.run([sys.executable, "-I", str(ROOT / "tools/design/make-installer-icon.py")], check=True)
    print(f"make-app-icon: {ICON.relative_to(ROOT)}; rendered {', '.join(done) or 'nothing (no ictool)'} → build/icon/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
