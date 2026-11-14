// Standalone repro (Q-015 r5, M9.T03 "Element has no description" on the main window's content column): a plain
// SwiftUI NavigationSplitView on macOS 26 puts its detail column in an unnamed AXGroup with exactly the split view's
// frame (the detail runs under the floating sidebar). A SwiftUI label cannot reach that group; an AppKit label on the
// column's own view can, which is what MainWindow does (`splitColumnAccessibilityLabel`, same rule as below):
//   plain       detail content <- AXGroup desc="" (= split view frame) <- AXSplitGroup
//   swiftui     .accessibilityElement(children: .contain).accessibilityLabel("Chat") on the detail content: the label
//               lands on a new wrapper group; the column group above it stays unnamed
//   appkit      setAccessibilityLabel on the column's view (the NSHostingView<ColumnView, …> under the split view
//               item's wrapper): the column group itself is named, its children unchanged
//   swiftc -swift-version 5 -O -o /tmp/detail navsplit-detail-group.swift && /tmp/detail plain swiftui appkit
// macOS 26.x output (2026-11-11):
//   plain    AXStaticText id=detailText <- AXGroup desc="" frame=split <- AXSplitGroup
//   swiftui  AXStaticText id=detailText <- AXGroup desc=Chat <- AXGroup desc="" frame=split <- AXSplitGroup
//   appkit   AXStaticText id=detailText <- AXGroup desc=Chat frame=split <- AXSplitGroup
import AppKit
import ApplicationServices
import SwiftUI

/// Hidden probe that names the nearest SwiftUI-made AXGroup view above it through AppKit (variant `appkit`).
final class Namer: NSView {
    var enabled = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var isHidden: Bool { get { true } set {} }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard enabled else { return }
        DispatchQueue.main.async { [self] in
            // The rule MainWindow's splitColumnAccessibilityLabel uses: the ancestor whose parent is the split view
            // item's wrapper (an NSHostingView<ColumnView, …>).
            var v = superview
            while let x = v, !(x.superview?.superview is NSSplitView) { v = x.superview }
            v?.setAccessibilityLabel("Chat")
        }
    }
}
struct NamerView: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> Namer { let n = Namer(); n.enabled = enabled; return n }
    func updateNSView(_ v: Namer, context: Context) {}
}
struct Root: View {
    let v: String
    var content: some View {
        Text("detail").accessibilityIdentifier("detailText").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        NavigationSplitView {
            List { Text("New chat"); Text("Search") }
        } detail: {
            switch v {
            case "swiftui": content.accessibilityElement(children: .contain).accessibilityLabel("Chat")
            case "appkit": content.background(NamerView(enabled: true))
            default: content
            }
        }
    }
}
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = ax(e, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = ax(e, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func axFind(_ e: AXUIElement, _ pred: (AXUIElement) -> Bool, _ d: Int = 0) -> AXUIElement? {
    if pred(e) { return e }
    if d > 40 { return nil }
    for k in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = axFind(k, pred, d + 1) { return f } }
    return nil
}
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let variants = Array(CommandLine.arguments.dropFirst())
var windows: [NSWindow] = []
for (i, v) in variants.enumerated() {
    let w = NSWindow(contentRect: NSRect(x: CGFloat(i * 620), y: 100, width: 600, height: 400),
                     styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Root(v: v))
    w.title = v
    w.orderFrontRegardless(); windows.append(w)
}
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 4)
    for w in (ax(AXUIElementCreateApplication(getpid()), "AXWindows") as? [AXUIElement]) ?? [] {
        let title = ax(w, "AXTitle") as? String ?? ""
        guard let split = axFind(w, { ax($0, "AXRole") as? String == "AXSplitGroup" }) else {
            let root = (ax(w, "AXChildren") as? [AXUIElement])?.first
            print(title.padding(toLength: 8, withPad: " ", startingAt: 0), "no split group in the window (AXGroup has",
                  ((root.flatMap { ax($0, "AXChildren") as? [AXUIElement] }) ?? []).count, "children)")
            continue
        }
        guard let text = axFind(w, { ax($0, "AXIdentifier") as? String == "detailText" }) else { print(title, "no detail"); continue }
        var chain = "AXStaticText id=detailText"
        var c = ax(text, "AXParent") as! AXUIElement?
        while let x = c {
            let role = ax(x, "AXRole") as? String ?? "?"
            if role == "AXSplitGroup" { chain += " <- AXSplitGroup"; break }
            chain += " <- \(role) desc=\(ax(x, "AXDescription") as? String ?? "\"\"")" + (frame(x) == frame(split) ? " frame=split" : "")
            c = ax(x, "AXParent") as! AXUIElement?
        }
        print(title.padding(toLength: 8, withPad: " ", startingAt: 0), chain)
    }
    exit(0)
}
app.run()
