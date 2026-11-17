// set-icon <icns> <path>: give <path> a Finder custom icon (package-dmg.sh: the DMG's Applications drop target).
import AppKit
guard CommandLine.arguments.count == 3, let img = NSImage(contentsOfFile: CommandLine.arguments[1]) else { exit(2) }
exit(NSWorkspace.shared.setIcon(img, forFile: CommandLine.arguments[2], options: []) ? 0 : 1)
