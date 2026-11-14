// Keeps a toolbar item centred on the *window* (R-001 AC2: |title centre − window centre| ≤ 2 pt). The unified
// toolbar's `.principal` slot centres over the detail column when the sidebar is open, so the title is shifted
// by the measured difference. The reader sits outside the offset, so it always measures the natural position
// (no feedback loop); it re-measures on window resize and on any ancestor frame change (sidebar toggle, title).
import AppKit
import SwiftUI

extension View {
    func centeredInWindow() -> some View { modifier(WindowCentered()) }
}

private struct WindowCentered: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(CentreReader { delta in
                if abs(-delta - offset) > 0.25 { offset = -delta }
            })
    }
}

private struct CentreReader: NSViewRepresentable {
    /// Called with (natural midX − window centre) in points.
    let onDelta: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onDelta = onDelta
        return v
    }

    func updateNSView(_ v: ReaderView, context: Context) {
        v.onDelta = onDelta
        v.measureSoon()
    }

    final class ReaderView: NSView {
        var onDelta: ((CGFloat) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.measureSoon() }
            })
            var v: NSView? = self
            while let view = v {
                view.postsFrameChangedNotifications = true
                observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measureSoon() }
                })
                v = view.superview
            }
            measureSoon()
        }

        override func layout() {
            super.layout()
            measureSoon()
        }

        /// Measures now-ish and again after the toolbar's own layout pass has settled.
        func measureSoon() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
            for delay in [0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.measure() }
            }
        }

        private func measure() {
            guard let window, bounds.width > 0 else { return }
            let f = convert(bounds, to: nil)
            onDelta?(f.midX - window.frame.width / 2)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
