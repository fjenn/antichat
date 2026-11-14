// Standalone repro (Q-015 r6, evidence for the KeyboardShortcuts upstream issue in docs/prd/M11-candidates.md §G): an
// NSSearchField whose cancel-button cell is taken away and put back (what KeyboardShortcuts' RecorderCocoa does to
// centre its placeholder: `cancelButtonCell = nil`, later restored) keeps an AXClearButton that its AXChildren no
// longer list, so the clear button is reachable only through that attribute: the audit's element-less
// "Parent/Child mismatch". An untouched NSSearchField lists its clear button. Nothing AntiChat-specific is involved.
//   swiftc -swift-version 5 -O -o /tmp/swap searchfield-cancel-cell-swap.swift && /tmp/swap plain && /tmp/swap swap
// macOS 26.x output (2026-11-11):
//   plain  clear button listed in AXChildren=true,  AXParent is the field=true, children=2
//   swap   clear button listed in AXChildren=false, AXParent is the field=true, children=0
import AppKit
import ApplicationServices

setbuf(stdout, nil)
let mode = CommandLine.arguments.dropFirst().first ?? "swap"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: NSRect(x: 60, y: 300, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
let field = NSSearchField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
field.stringValue = "⌥⌘Space"
w.contentView!.addSubview(field)
w.orderFrontRegardless()
if mode == "swap" {
    let cell = field.cell as! NSSearchFieldCell
    cell.searchButtonCell = nil  // as RecorderCocoa does
    let saved = cell.cancelButtonCell
    cell.cancelButtonCell = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cell.cancelButtonCell = saved; field.needsDisplay = true }
}
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 1.5)
    for win in (ax(AXUIElementCreateApplication(getpid()), "AXWindows") as? [AXUIElement]) ?? [] {
        func walk(_ e: AXUIElement) {
            if (ax(e, "AXSubrole") as? String) == "AXSearchField", let c = ax(e, "AXClearButton") {
                let clear = c as! AXUIElement
                let kids = (ax(e, "AXChildren") as? [AXUIElement]) ?? []
                let p = ax(clear, "AXParent") as! AXUIElement?
                print(mode.padding(toLength: 6, withPad: " ", startingAt: 0),
                      "clear button listed in AXChildren=\(kids.contains { CFEqual($0, clear) }),",
                      "AXParent is the field=\(p.map { CFEqual($0, e) } ?? false), children=\(kids.count)")
            }
            for k in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(k) }
        }
        walk(win)
    }
    exit(0)
}
app.run()
