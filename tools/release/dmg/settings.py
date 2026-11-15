# dmgbuild settings for the AntiChat DMG (M10.T02 step 1; R-225 AC1). Passed by tools/release/package-dmg.sh with
# `-D app=<path> -D background=<tiff> -D format=UDRW`; dmgbuild writes the window layout (.DS_Store) and the background
# alias itself, so no Finder scripting (no Automation grant, no Finder window taking focus; A-M10-T02a). package-dmg.sh
# then repairs the background bookmark (tools/release/dmg/fix-background-bookmark.py) and converts the image to ULFO.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)
appname = os.path.basename(app)
# The mounted installer is named and badged (tools/design/make-installer-icon.py) so it never looks like the app.
volume_name = "AntiChat Installer"
format = defines.get("format", "ULFO")  # noqa: F821 (ci-release §5: ULFO, fallback UDZO)
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
# No `hide_extensions`: dmgbuild sets the hide-extension flag as a com.apple.FinderInfo xattr on the bundle root, which
# `codesign --verify --strict` rejects on the copied app ("detritus not allowed"; M10.T09 AT-FA-01). Finder already
# hides the .app extension by default.
icon_locations = {appname: (180, 200), "Applications": (480, 200)}
background = defines["background"]  # noqa: F821
icon = defines.get("icon")  # noqa: F821 (tools/release/dmg/VolumeIcon.icns from tools/design/make-app-icon.py)
# 660×452 frame = a 32 pt title bar + a 660×420 content area, the background's size (tools/release/dmg/background.tiff).
# With a 420 pt frame Finder (macOS 26) clipped the bottom 32 pt, the "Drag to Applications · Requires …" line.
window_rect = ((200, 120), (660, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
