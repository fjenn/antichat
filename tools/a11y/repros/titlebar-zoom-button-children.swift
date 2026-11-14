// Standalone repro (Q-015 r5, evidence for the `_XCUI:ZoomWindow` entry in tools/a11y/audit-ignores.yml, and again
// for `_XCUI:FullScreenWindow`): on macOS 26 AppKit's own green title-bar button carries an unnamed AXGroup child that
// is not consistent with it. The button lists the group in AXChildren, but the group's AXParent is another element,
// which does not list it: the audit's "Parent/Child mismatch". It is the same widget whether the button is the
// full-screen button (AXFullScreenButton) or the plain zoom button (AXZoomButton: a window that cannot go full
// screen, like SwiftUI's Settings window, or a window while a sheet is attached). Freshly made bare windows do not
// grow the child (`own` below, which activates this process for about 3 s), so the evidence is the running apps.
//   swiftc -swift-version 5 -O -o /tmp/zoom titlebar-zoom-button-children.swift
//   /tmp/zoom others   # read-only: the green button of every window of the running apps (Terminal, Safari, …)
//   /tmp/zoom own      # three bare NSWindows of this process: full screen, fixed size, with a sheet
// macOS 26.x output (2026-11-11):
//   others: Terminal / Safari / TextEdit  AXFullScreenButton children=1 [AXGroup parentIsButton=false listedByParent=false]
//   own:    every window  children=0 (the child is not created for a new bare window, even after it was key)
import AppKit
import ApplicationServices

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func kids(_ e: AXUIElement) -> [AXUIElement] { (ax(e, "AXChildren") as? [AXUIElement]) ?? [] }

/// One line per green button of `app`'s windows: its child groups and whether parent and child agree.
func report(_ app: AXUIElement, _ name: String) {
    for w in (ax(app, "AXWindows") as? [AXUIElement]) ?? [] {
        let title = ax(w, "AXTitle") as? String ?? ""
        for b in kids(w) where ["AXZoomButton", "AXFullScreenButton"].contains(ax(b, "AXSubrole") as? String ?? "") {
            var line = "\(name) \"\(title)\" \(ax(b, "AXSubrole") as? String ?? "") children=\(kids(b).count)"
            for c in kids(b) {
                let p = ax(c, "AXParent") as! AXUIElement?
                let parentIsButton = p.map { CFEqual($0, b) } ?? false
                let listedByParent = p.map { pp in kids(pp).contains { CFEqual($0, c) } } ?? false
                line += " [\(ax(c, "AXRole") as? String ?? "?") desc=\"\(ax(c, "AXDescription") as? String ?? "")\""
                line += " parentIsButton=\(parentIsButton) listedByParent=\(listedByParent)]"
            }
            print(line)
        }
    }
}

setbuf(stdout, nil)
let mode = CommandLine.arguments.dropFirst().first ?? "others"
if mode == "others" {
    for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular {
        report(AXUIElementCreateApplication(r.processIdentifier), r.localizedName ?? "?")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
func window(_ title: String, _ style: NSWindow.StyleMask, x: CGFloat) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: x, y: 200, width: 360, height: 240), styleMask: style, backing: .buffered, defer: false)
    w.title = title
    w.orderFrontRegardless()
    return w
}
let fullScreen = window("full-screen", [.titled, .closable, .miniaturizable, .resizable], x: 40)
let fixed = window("fixed-size", [.titled, .closable, .miniaturizable], x: 420)
let withSheet = window("with-sheet", [.titled, .closable, .miniaturizable, .resizable], x: 800)
let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    app.activate()
    for (i, w) in [fullScreen, fixed, withSheet].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(i + 1)) { w.makeKeyAndOrderFront(nil) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withSheet.beginSheet(sheet) }
}
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 3.5)
    report(AXUIElementCreateApplication(getpid()), "own")
    exit(0)
}
app.run()
