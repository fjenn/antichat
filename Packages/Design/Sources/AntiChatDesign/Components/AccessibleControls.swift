// M9.T03 (Q-015 r5): the press / show-menu actions SwiftUI leaves off two macOS 26 controls. VoiceOver (VO-Space,
// VO-Shift-M), Switch Control and Voice Control act through these actions, and the accessibility audit reports each
// missing one as "Action is missing" (tools/a11y/repros/swiftui-control-actions.swift shows both on a bare window):
// - a `.switch` Toggle with hidden labels is an AXCheckBox (subrole AXToggle) with no AXPress at all;
// - a menu-style Picker or a Menu is SwiftUI's own NSPopUpButton subclass with AXPress only, where AppKit's
//   NSPopUpButton also offers AXShowMenu.
import AppKit
import SwiftUI

/// The `.switch` style plus the press action SwiftUI drops when the labels are hidden (every Settings switch: the row
/// shows the label). The action follows `.disabled`, like a click.
public struct AccessibleSwitchToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { AccessibleSwitch(configuration: configuration) }
}

public extension ToggleStyle where Self == AccessibleSwitchToggleStyle {
    /// `.switch` with a working VoiceOver press (use instead of `.switch`).
    static var accessibleSwitch: AccessibleSwitchToggleStyle { AccessibleSwitchToggleStyle() }
}

private struct AccessibleSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labels
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let toggle = Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)  // a11y-lint: ok the style's own switch; the caller's Toggle carries the identifier
        if labels == .hidden {
            // With the labels shown SwiftUI keeps its own AXPress; a second one would make a press toggle twice.
            toggle.accessibilityAction { if isEnabled { configuration.$isOn.wrappedValue.toggle() } }
        } else {
            toggle
        }
    }
}

/// The automatic DisclosureGroup plus the press action its AXDisclosureTriangle lacks (it has no action at all).
public struct AccessibleDisclosureGroupStyle: DisclosureGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        DisclosureGroup(isExpanded: configuration.$isExpanded) { configuration.content } label: { configuration.label }
            .disclosureGroupStyle(.automatic)  // not this style again (it would recurse)
            .accessibilityAction { withAnimation { configuration.$isExpanded.wrappedValue.toggle() } }
    }
}

public extension DisclosureGroupStyle where Self == AccessibleDisclosureGroupStyle {
    /// The automatic style with a working VoiceOver press.
    static var accessible: AccessibleDisclosureGroupStyle { AccessibleDisclosureGroupStyle() }
}

public extension View {
    /// Adds AXShowMenu to a menu-style Picker or a Menu: it opens the same menu a click opens. Apply it to the
    /// control itself (not to a container), and not to a Menu nested in another menu.
    func accessibilityShowMenu() -> some View { modifier(ShowMenuAction()) }
}

private struct ShowMenuAction: ViewModifier {
    @State private var locator = PopUpLocator()

    func body(content: Content) -> some View {
        content
            .accessibilityAction(.showMenu) { locator.open() }
            .background(PopUpLocatorAnchor(locator: locator))
    }
}

/// Finds the pop-up button SwiftUI made for the control: the smallest NSPopUpButton in the window that contains the
/// centre of a hidden anchor laid out behind the control (the same frame).
@MainActor
final class PopUpLocator {
    weak var anchor: NSView?

    func open() {
        guard let anchor, let window = anchor.window, let root = window.contentView?.superview ?? window.contentView
        else { return }
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
        // After the action returns: the menu runs its own tracking loop, which would hold the AX request open.
        if let pop = best?.0 { DispatchQueue.main.async { pop.performClick(nil) } }
    }
}

private struct PopUpLocatorAnchor: NSViewRepresentable {
    let locator: PopUpLocator

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        locator.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { locator.anchor = view }

    /// Hidden and out of both hit tests, like the DEBUG probe anchors (Q-015 r3): a shown NSView over the control
    /// took the accessibility hit test away from it.
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
        override var isHidden: Bool { get { true } set {} }
    }
}
