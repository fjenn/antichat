// Standalone repro (Q-015 r4, docs/prd/M9-T03-hit-test-feedback.md): a `.contain` container with
// `.contentShape(Rectangle())` gives the child that appears alone in it the container's whole AX frame, and it keeps it
// after more children arrive. HOV=cs|both shows the bug; HOV=bgcs (clear background with the shape, the fix), hover
// and none do not.
//   swiftc -swift-version 5 -O -o /tmp/dot container-contentshape-frame.swift && HOV=cs /tmp/dot plain text
import AppKit
import SwiftUI
import ApplicationServices

let verbDelay = Double(ProcessInfo.processInfo.environment["VERB"] ?? "2.5")!
let start = Date()

struct Dot: View {
    let v: String
    var body: some View {
        switch v {
        case "static":
            Circle().fill(.black).frame(width: 8, height: 8)
                .accessibilityElement(children: .ignore).accessibilityLabel("Thinking").accessibilityIdentifier("dot")
        case "text":
            Text("●").font(.system(size: 8))
                .accessibilityLabel("Thinking").accessibilityIdentifier("dot")
        case "img":
            Image(systemName: "circle.fill").font(.system(size: 8))
                .accessibilityLabel("Thinking").accessibilityIdentifier("dot")
        default:
            Color.clear.frame(width: 8, height: 8)
                .overlay { Circle().fill(.black).phaseAnimator([false, true]) { d, p in d.opacity(p ? 0.35 : 1).scaleEffect(p ? 0.8 : 1) } animation: { _ in .easeInOut(duration: 0.6) } }
                .accessibilityElement(children: .ignore).accessibilityLabel("Thinking").accessibilityIdentifier("dot")
        }
    }
}
final class M: ObservableObject { @Published var card = false; @Published var pending = true }
struct Status: View {
    let v: String
    var row: some View {
        HStack(spacing: 4) {
            Dot(v: v)
            TimelineView(.periodic(from: start, by: 0.25)) { ctx in
                Group { if ctx.date.timeIntervalSince(start) > verbDelay { Text("verb").transition(.opacity) } }
                    .animation(.default, value: ctx.date.timeIntervalSince(start) > verbDelay)
            }
        }.frame(minHeight: 24, alignment: .leading)
    }
    var body: some View {
        switch v {
        case "grp": row.accessibilityElement(children: .contain)
        case "grpid": row.accessibilityElement(children: .contain).accessibilityIdentifier("status")
        default: row
        }
    }
}
struct Msg: View {
    let v: String
    @ObservedObject var m: M
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.card { Text("activity"); VStack { Color.gray.frame(height: 200); Button("Cancel") {}.accessibilityIdentifier("btn") }.accessibilityElement(children: .contain).accessibilityIdentifier("card") }
            if m.pending { Status(v: v) }
        }
        .modifier(Hov())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("msg")
    }
}
struct Hov: ViewModifier {
    func body(content: Content) -> some View {
        switch ProcessInfo.processInfo.environment["HOV"] ?? "both" {
        case "cs": content.contentShape(Rectangle())
        case "hover": content.onHover { _ in }
        case "none": content
        case "inter": content.contentShape(.interaction, Rectangle()).onHover { _ in }

        case "bgcs": content.background { Color.clear.contentShape(Rectangle()) }.onHover { _ in }
        case "bgshape": content.background { Color.clear.contentShape(Rectangle()).onHover { _ in } }
        default: content.contentShape(Rectangle()).onHover { _ in }
        }
    }
}
struct Root: View {
    let v: String
    @ObservedObject var m: M
    var body: some View {
        ScrollView { LazyVStack { Msg(v: v, m: m) }.accessibilityElement(children: .contain).padding() }
    }
}
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func axFind(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if (ax(e, "AXIdentifier") as? String) == id { return e }
    if d > 30 { return nil }
    for k in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = axFind(k, id, d + 1) { return f } }
    return nil
}
func frame(_ e: AXUIElement?) -> String {
    guard let e else { return "nil" }
    var p = CGPoint.zero, sz = CGSize.zero
    if let v = ax(e, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = ax(e, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &sz) }
    return "(\(Int(p.x)),\(Int(p.y)),\(Int(sz.width)),\(Int(sz.height)))"
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let variants = Array(CommandLine.arguments.dropFirst())
var models: [M] = []
var windows: [NSWindow] = []
for (i, v) in variants.enumerated() {
    let m = M(); models.append(m)
    let w = NSWindow(contentRect: NSRect(x: CGFloat(i * 410), y: 100, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Root(v: v, m: m))
    w.level = .floating; w.orderFrontRegardless(); windows.append(w)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { for m in models { withAnimation { m.card = true } } }
Thread.detachNewThread {
    let appEl = AXUIElementCreateApplication(getpid())
    var out: [String] = []
    for t in [0.5, 4.0] {
        Thread.sleep(forTimeInterval: t == 0.5 ? 0.5 : 3.5)
        let wins = (ax(appEl, "AXWindows") as? [AXUIElement]) ?? []
        for w in wins {
            let d = axFind(w, "dot"); var p = CGPoint.zero
            if let v = ax(w, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
            let name = variants[Int(p.x) / 410]
            out.append("t=\(t) \(name) dot \(frame(d)) status \(frame(axFind(w, "status"))) msg \(frame(axFind(w, "msg")))")
        }
    }
    print(out.sorted().joined(separator: "\n"))
    DispatchQueue.main.sync {
        func find(_ e: Any, _ id: String) -> NSAccessibilityElementProtocol? {
            guard let o = e as? NSObject else { return nil }
            if (o as? NSAccessibilityProtocol)?.accessibilityIdentifier() == id { return o as? NSAccessibilityElementProtocol }
            for k in ((o as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []) { if let f = find(k, id) { return f } }
            return nil
        }
        for (i, w) in windows.enumerated() { print("inproc", variants[i], find(w.contentView!, "dot")?.accessibilityFrame() ?? .zero) }
    }
    exit(0)
}
app.run()
