// Standalone repro (Q-015 r5, M9.T03 "Action is missing"): the accessibility actions SwiftUI gives four macOS 26
// controls, next to AppKit's own, and the fixes in Packages/Design/.../Components/AccessibleControls.swift (copied in
// below so this file builds alone). It performs each action through the AX API and reports what happened.
//   swiftc -swift-version 5 -O -o /tmp/acts swiftui-control-actions.swift && /tmp/acts
// macOS 26.x output (2026-11-11):
//   switch.labelsHidden        AXCheckBox/AXToggle  []                       <- no press at all
//   switch.labelsShown         AXCheckBox/AXSwitch  [AXPress]
//   switch.fixed               AXCheckBox/AXToggle  [AXPress]                AXPress -> isOn true->false
//   picker.menu                AXPopUpButton        [AXPress]                <- AppKit's NSPopUpButton: [AXShowMenu, AXPress]
//   picker.fixed               AXPopUpButton        [AXPress, AXShowMenu]    AXShowMenu -> menu opened [alpha, beta]
//   menu                       AXMenuButton         [AXPress]
//   menu.fixed                 AXMenuButton         [AXPress, AXShowMenu]    AXShowMenu -> menu opened [one, two]
//   tapRow (onTapGesture + .isButton)  AXButton     []                       <- vendored palette rows
//   disclosure                 AXDisclosureTriangle []
import AppKit
import ApplicationServices
import SwiftUI

// ---- copy of AccessibleControls.swift (the fix) ----
struct AccessibleSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { AccessibleSwitch(configuration: configuration) }
}
struct AccessibleSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labels
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let toggle = Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        if labels == .hidden {
            toggle.accessibilityAction { if isEnabled { configuration.$isOn.wrappedValue.toggle() } }
        } else {
            toggle
        }
    }
}
@MainActor final class PopUpLocator {
    weak var anchor: NSView?
    func open() {
        guard let anchor, let window = anchor.window, let root = window.contentView?.superview ?? window.contentView else { return }
        let frame = anchor.convert(anchor.bounds, to: nil)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var best: (NSPopUpButton, CGFloat)?
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if let pop = sub as? NSPopUpButton, pop.isEnabled {
                    let f = pop.convert(pop.bounds, to: nil)
                    if f.contains(centre), best.map({ f.width * f.height < $0.1 }) ?? true { best = (pop, f.width * f.height) }
                }
                walk(sub)
            }
        }
        walk(root)
        if let pop = best?.0 { DispatchQueue.main.async { pop.performClick(nil) } }
    }
}
struct PopUpLocatorAnchor: NSViewRepresentable {
    let locator: PopUpLocator
    func makeNSView(context: Context) -> NSView { let v = AnchorView(); locator.anchor = v; return v }
    func updateNSView(_ view: NSView, context: Context) { locator.anchor = view }
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
        override var isHidden: Bool { get { true } set {} }
    }
}
struct ShowMenuAction: ViewModifier {
    @State private var locator = PopUpLocator()
    func body(content: Content) -> some View {
        content.accessibilityAction(.showMenu) { locator.open() }.background(PopUpLocatorAnchor(locator: locator))
    }
}
// ---- end of copy ----

final class Model: ObservableObject { @Published var on = true; @Published var pick = 1; @Published var open = false }
let model = Model()

struct Root: View {
    @ObservedObject var m: Model
    var body: some View {
        Form {
            Toggle("hidden", isOn: $m.on).toggleStyle(.switch).labelsHidden().accessibilityIdentifier("switch.labelsHidden")
            Toggle("shown", isOn: $m.on).toggleStyle(.switch).accessibilityIdentifier("switch.labelsShown")
            Toggle("fixed", isOn: $m.on).toggleStyle(AccessibleSwitchToggleStyle()).labelsHidden().accessibilityIdentifier("switch.fixed")
            Picker("p", selection: $m.pick) { Text("alpha").tag(1); Text("beta").tag(2) }.pickerStyle(.menu).labelsHidden()
                .accessibilityIdentifier("picker.menu")
            Picker("p", selection: $m.pick) { Text("alpha").tag(1); Text("beta").tag(2) }.pickerStyle(.menu).labelsHidden()
                .modifier(ShowMenuAction()).accessibilityIdentifier("picker.fixed")
            Menu { Button("one") {}; Button("two") {} } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden)
                .accessibilityLabel("More").accessibilityIdentifier("menu").fixedSize()
            Menu { Button("one") {}; Button("two") {} } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden)
                .accessibilityLabel("More").modifier(ShowMenuAction()).accessibilityIdentifier("menu.fixed").fixedSize()
            Text("tap row").contentShape(Rectangle()).onTapGesture {}.accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton).accessibilityIdentifier("tapRow")
            DisclosureGroup("Advanced", isExpanded: $m.open) { Text("x") }.accessibilityIdentifier("disclosure")
        }
        .formStyle(.grouped)
    }
}

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func actions(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyActionNames(e, &n); return (n as? [String]) ?? [] }
func axFind(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if (ax(e, "AXIdentifier") as? String) == id { return e }
    if d > 40 { return nil }
    for k in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = axFind(k, id, d + 1) { return f } }
    return nil
}
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: NSRect(x: 40, y: 200, width: 420, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
w.contentView = NSHostingView(rootView: Root(m: model))
w.orderFrontRegardless()
let pop = NSPopUpButton(frame: NSRect(x: 300, y: 10, width: 100, height: 26)); pop.addItems(withTitles: ["a", "b"])
pop.setAccessibilityIdentifier("appkit.popup"); w.contentView!.addSubview(pop)
var opened: [String] = []
NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
    let m = n.object as! NSMenu
    opened.append(m.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))
    m.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.2, inModes: [.common, .eventTracking])
}
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 2)
    let win = (ax(AXUIElementCreateApplication(getpid()), "AXWindows") as? [AXUIElement])?.first
    for id in ["switch.labelsHidden", "switch.labelsShown", "switch.fixed", "appkit.popup", "picker.menu", "picker.fixed",
               "menu", "menu.fixed", "tapRow", "disclosure"] {
        guard let win, let e = axFind(win, id) else { print(id, "not found"); continue }
        let role = "\(ax(e, "AXRole") as? String ?? "?")/\(ax(e, "AXSubrole") as? String ?? "")"
        var result = ""
        if id == "switch.fixed" {
            let before = DispatchQueue.main.sync { model.on }
            AXUIElementPerformAction(e, "AXPress" as CFString); Thread.sleep(forTimeInterval: 0.5)
            result = "AXPress -> isOn \(before)->\(DispatchQueue.main.sync { model.on })"
        }
        if id.hasSuffix(".fixed"), id != "switch.fixed" {
            DispatchQueue.main.sync { opened = [] }
            AXUIElementPerformAction(e, "AXShowMenu" as CFString); Thread.sleep(forTimeInterval: 1)
            result = "AXShowMenu -> " + DispatchQueue.main.sync { opened.isEmpty ? "no menu" : "menu opened [\(opened[0])]" }
        }
        print(id.padding(toLength: 22, withPad: " ", startingAt: 0), role.padding(toLength: 22, withPad: " ", startingAt: 0), actions(e), result)
    }
    exit(0)
}
app.run()
