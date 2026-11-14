#!/usr/bin/env python3
"""make audit: the owner try-out preview (ANTICHAT_TRYOUT_PREVIEW) can never reach a release build.

Checks:
  1. ModelPack.shipped outside the preview branch is exactly SHIPPED (each pack's milestone close widened it: Voice at M3.T14, Photo at M4.T16, Video at M5.T14; every pack ships now).
  2. The compile condition is set only by build-release.sh when TRYOUT_PREVIEW=1, which refuses Developer ID
     signing and release keys; `make build-release` never sets TRYOUT_PREVIEW; `make build-tryout` writes to
     build/tryout, not build/release.
  3. ANTICHAT_TRYOUT_PREVIEW appears only in the files that implement the preview.
  4. If a release build exists (build/release/build.json), it is not a preview.
Stdlib only; exit 1 on any violation.
"""
import json, pathlib, re, subprocess, sys

# The non-preview shipped set; widened at each pack's milestone close (ShippedPacksDefaultTests says the same).
SHIPPED = "[.chat, .voice, .photo, .video]"
ROOT = pathlib.Path(__file__).resolve().parents[2]
ALLOWED = {
    "Packages/Platform/Sources/AntiChatPlatform/Catalog/Selection.swift",
    "Packages/Platform/Sources/AntiChatPlatform/Runtimes/RuntimeInstaller.swift",
    "Packages/Platform/Sources/AntiChatPlatform/Runtimes/TryoutPreview.swift",
    "Packages/Platform/Tests/AntiChatPlatformTests/ShippedPacksDefaultTests.swift",
    "tools/release/build-release.sh",
    "Makefile",
    "tools/ci/tryout-guard.py",
}


def recipe(makefile: str, target: str) -> str:
    m = re.search(rf"^{re.escape(target)}:.*\n((?:\t.*\n)*)", makefile, re.M)
    return (m.group(0) if m else "")


def main() -> int:
    errors = []
    sel = (ROOT / "Packages/Platform/Sources/AntiChatPlatform/Catalog/Selection.swift").read_text()
    m = re.search(r"#if ANTICHAT_TRYOUT_PREVIEW\n(.*?)#else\n(.*?)#endif", sel, re.S)
    if not m:
        plain = re.findall(r"static let shipped: Set<ModelPack> = (\[[^\]]*\])", sel)
        if plain != [SHIPPED]:
            errors.append(f"Selection.swift: shipped is {plain}, expected {SHIPPED}")
    else:
        default = re.findall(r"static let shipped: Set<ModelPack> = (\[[^\]]*\])", m.group(2))
        if default != [SHIPPED]:
            errors.append(f"Selection.swift: the non-preview shipped set is {default}, expected {SHIPPED}")
        outside = sel[:m.start()] + sel[m.end():]
        if "static let shipped" in outside:
            errors.append("Selection.swift: a second shipped set outside the #if/#else")

    mk = (ROOT / "Makefile").read_text()
    br = recipe(mk, "build-release")
    if not br:
        errors.append("Makefile: no build-release target")
    elif "TRYOUT" in br:
        errors.append("Makefile: build-release must not set TRYOUT_PREVIEW")
    bt = recipe(mk, "build-tryout")
    if bt and ("OUT=build/tryout" not in bt or "TRYOUT_PREVIEW=1" not in bt):
        errors.append("Makefile: build-tryout must set TRYOUT_PREVIEW=1 and OUT=build/tryout")

    sh = (ROOT / "tools/release/build-release.sh").read_text()
    if not re.search(r'if \[\[ "\$tryout" == 1 \]\]; then\n\s+if \[\[ "\$mode" == devid \|\| "\$keys" == release \]\]; then\n'
                     r'.*?\n\s+exit 1', sh, re.S):
        errors.append("build-release.sh: TRYOUT_PREVIEW must refuse devid signing and release keys")
    if sh.count("ANTICHAT_TRYOUT_PREVIEW'") != 1 or "TRYOUT_PREVIEW:-0" not in sh:
        errors.append("build-release.sh: ANTICHAT_TRYOUT_PREVIEW must be added only behind TRYOUT_PREVIEW=1 (default 0)")

    files = subprocess.run(["git", "-C", str(ROOT), "grep", "-l", "ANTICHAT_TRYOUT_PREVIEW", "--", ".", ":!fixtures"],
                           capture_output=True, text=True).stdout.split()
    for f in files:
        if f not in ALLOWED:
            errors.append(f"{f}: uses ANTICHAT_TRYOUT_PREVIEW (only the preview's own files may)")

    bj = ROOT / "build/release/build.json"
    if bj.exists():
        try:
            if json.loads(bj.read_text()).get("tryout_preview"):
                errors.append("build/release/build.json: a release build is marked tryout_preview")
        except ValueError:
            pass

    for e in errors:
        print(f"tryout-guard: {e}")
    print(f"tryout-guard: {'FAIL' if errors else 'ok'} ({len(errors)} problem(s))")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
