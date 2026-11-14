// Standalone repro (Q-015 r4, evidence for the `sidebar` entry in tools/a11y/audit-ignores.yml): a plain SwiftUI
// NavigationSplitView puts its sidebar List inside an unnamed AXGroup (the column), with or without a footer inset,
// and a label set from SwiftUI lands on a new wrapper group, not on that one.
//   swiftc -swift-version 5 -O -o /tmp/side navsplit-sidebar-group.swift && /tmp/side plain inset insetlabel vstack detaillabel
// Q-015 r5: the detail column too (`detail` chain; `detaillabel` = our content as a labelled container).
// macOS 26.x output (2026-11-10), every variant: AXOutline id=sidebar desc=Sidebar <- AXScrollArea <- AXGroup desc=""
import AppKit
import SwiftUI
import ApplicationServices

struct Root: View {
    let v: String
    var list: some View { List { Text("New chat"); Text("Search") }.accessibilityIdentifier("sidebar") }
    var body: some View {
        NavigationSplitView {
            switch v {
            case "inset": list.safeAreaInset(edge: .bottom, spacing: 0) { Text("footer") }
            case "insetlabel": list.safeAreaInset(edge: .bottom, spacing: 0) { Text("footer") }.accessibilityElement(children: .contain).accessibilityLabel("Sidebar")
            case "vstack": VStack(spacing: 0) { list; Text("footer") }
            default: list
            }
        } detail: {
            // Q-015 r5: the detail column. `detaillabel` names our content (a labelled `.contain` container).
            if v == "detaillabel" {
                VStack { Text("detail") }.accessibilityElement(children: .contain).accessibilityLabel("Chat").accessibilityIdentifier("detail")
            } else {
                Text("detail").accessibilityIdentifier("detail")
            }
        }
    }
}
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func axFind(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if (ax(e, "AXIdentifier") as? String) == id { return e }
    if d > 40 { return nil }
    for k in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = axFind(k, id, d + 1) { return f } }
    return nil
}
func axDesc(_ e: AXUIElement) -> String {
    "\(ax(e, "AXRole") as? String ?? "?") id=\(ax(e, "AXIdentifier") as? String ?? "") desc=\(ax(e, "AXDescription") as? String ?? "")"
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let variants = Array(CommandLine.arguments.dropFirst())
var windows: [NSWindow] = []
for (i, v) in variants.enumerated() {
    let w = NSWindow(contentRect: NSRect(x: CGFloat(i * 620), y: 100, width: 600, height: 400), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Root(v: v))
    w.title = v
    w.orderFrontRegardless(); windows.append(w)
}
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 2)
    let appEl = AXUIElementCreateApplication(getpid())
    for w in (ax(appEl, "AXWindows") as? [AXUIElement]) ?? [] {
        for id in ["sidebar", "detail"] {
            guard let b = axFind(w, id) else { print(ax(w, "AXTitle") ?? "", "no \(id)"); continue }
            var c: AXUIElement? = b; var s = ""
            for _ in 0..<5 { guard let x = c else { break }; s += " <- " + axDesc(x); c = ax(x, "AXParent") as! AXUIElement? }
            print(ax(w, "AXTitle") ?? "", id, s)
        }
    }
    exit(0)
}
app.run()
