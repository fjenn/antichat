// fix/overlay-field-focus: an AppKit-backed "focus this field when it appears" for a SwiftUI TextField. A SwiftUI focus
// request made while the field is not in the window yet is dropped, and a `@FocusState` that reads `true` does not
// prove AppKit moved the first responder (Describe the change opened from Edit with the composer, an NSTextView, still
// holding it). The anchor sits behind the field (`.background`), finds the AppKit text field drawn over its own frame
// and makes it first responder, retrying until it holds (≤ 1 s), once per appearance.
import AppKit
import SwiftUI

extension View {
    /// Gives this TextField the keyboard focus when it appears (when `active`). `inside`: the view is a container
    /// (the vendored ⌘K palette) and its first editable field anywhere within its frame takes the focus (Q-015 r7).
    func focusOnAppear(_ active: Bool = true, inside: Bool = false) -> some View {
        background(TextFieldFocusAnchor(active: active, inside: inside))
    }
}

struct TextFieldFocusAnchor: NSViewRepresentable {
    let active: Bool
    var inside = false

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ v: AnchorView, context: Context) {
        v.active = active
        v.inside = inside
        v.schedule()
    }

    final class AnchorView: NSView {
        var active = false
        var inside = false
        /// The focus was given (or the user moved on) for this appearance.
        private var done = false
        private var scheduled = false

        // Never in the way of a click or the accessibility tree.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { done = false } else { schedule() }
        }

        func schedule(tries: Int = 20) {
            guard active, !done, !scheduled, window != nil else { return }
            scheduled = true
            // After this layout pass (a run-loop perform, so a nested run loop such as a test settle() runs it too).
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduled = false
                    if self.attempt() { self.done = true; return }
                    guard tries > 1 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        MainActor.assumeIsolated { self?.schedule(tries: tries - 1) }
                    }
                }
            }
        }

        /// True when the field has the focus now (or another text field took it: the user's choice).
        private func attempt() -> Bool {
            guard let window, let field = field(in: window) else { return false }
            let fr = window.firstResponder
            if let editor = fr as? NSText, editor.delegate === field { return true }
            if fr is NSText, !(fr is ComposerNSTextView) { return true }  // another field is being edited
            return window.makeFirstResponder(field)
        }

        /// The editable AppKit text field drawn over this anchor's frame (SwiftUI's TextField backing).
        private func field(in window: NSWindow) -> NSTextField? {
            guard let root = window.contentView, bounds.width > 0, bounds.height > 0 else { return nil }
            let mine = convert(bounds, to: nil)
            let center = CGPoint(x: mine.midX, y: mine.midY)
            var best: (NSTextField, CGFloat)?
            func walk(_ v: NSView) {
                if v.isHidden { return }
                if let f = v as? NSTextField, f.isEditable, f.isEnabled {
                    let r = f.convert(f.bounds, to: nil)
                    if inside ? r.intersects(mine) && mine.contains(CGPoint(x: r.midX, y: r.midY)) : r.contains(center) {
                        let area = r.width * r.height
                        if best == nil || area < best!.1 { best = (f, area) }
                    }
                }
                for s in v.subviews { walk(s) }
            }
            walk(root)
            return best?.0
        }
    }
}
