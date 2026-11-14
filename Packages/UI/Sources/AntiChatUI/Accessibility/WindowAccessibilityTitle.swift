// M9.T01 step 2 (NFR-A2): VoiceOver announces the chat mode in the window title — "<title>, Evil mode chat" /
// "<title>, Incognito chat" — without changing what is drawn (the toolbar shows ToolbarTitle; the window's own
// title stays hidden). Set as the NSWindow accessibility title, re-applied when the chat or its mode changes.
import AntiChatDesign
import AppKit
import SwiftUI

enum WindowAccessibilityTitle {
    /// The spoken window title for a chat (pure; VoiceOverLabelTests/testEvilTitleAnnounced and the unit test).
    static func text(chatTitle: String?, evil: Bool, incognito: Bool) -> String {
        let t = (chatTitle?.isEmpty ?? true) ? CopyKey("side.untitled").string() : chatTitle!
        if incognito { return "\(t), \(CopyKey("a11y.incognitoChat").string())" }
        if evil { return "\(t), \(CopyKey("a11y.evilChat").string())" }
        return t
    }
}

extension View {
    /// Sets the hosting window's accessibility title (visual title unchanged) and names its hosting view.
    /// `windowTitle: false` names the hosting view only: the window keeps its own (drawn) title as its accessibility
    /// title — Settings, whose title is the selected section (Q-015 r7: pinning "Settings" made VoiceOver and XCUITest
    /// read "Settings" while the window showed "Capabilities").
    func windowAccessibilityTitle(_ title: String, windowTitle: Bool = true) -> some View {
        background(WindowAccessibilityTitleAnchor(title: title, windowTitle: windowTitle).frame(width: 0, height: 0)
            .accessibilityHidden(true))
    }
}

extension View {
    /// Names the NavigationSplitView column this view sits in. SwiftUI hosts each column in its own view, an unnamed
    /// AXGroup ("Element has no description", M9.T03 audit; the detail column has the whole window's frame on macOS
    /// 26), and a SwiftUI label lands on a new group inside it instead (tools/a11y/repros/navsplit-detail-group.swift).
    /// Use on the column's root content only.
    func splitColumnAccessibilityLabel(_ label: String) -> some View {
        background(SplitColumnLabelAnchor(label: label).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct SplitColumnLabelAnchor: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.label = label
        view.apply()
    }

    final class Anchor: NSView {
        var label = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }  // the split view is in place one pass later
        }
        func apply() {
            // The column's hosting view: the ancestor whose parent is the split view item's wrapper.
            var view = superview
            while let v = view, !(v.superview?.superview is NSSplitView) { view = v.superview }
            guard let column = view, column.accessibilityLabel() != label else { return }
            column.setAccessibilityLabel(label)
        }
    }
}

private struct WindowAccessibilityTitleAnchor: NSViewRepresentable {
    let title: String
    let windowTitle: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.title = title
        view.windowTitle = windowTitle
        view.apply()
    }

    final class Anchor: NSView {
        var title = ""
        var windowTitle = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            // The hosting view fills the window and is an unnamed group to accessibility ("Element has no
            // description" on every main screen, M9.T03 audit): it carries the window's spoken title too.
            if window.contentView?.accessibilityLabel() != title { window.contentView?.setAccessibilityLabel(title) }
            guard windowTitle, window.accessibilityTitle() != title else { return }
            window.setAccessibilityTitle(title)
        }
    }
}
