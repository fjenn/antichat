// IncognitoFrame (M1.T20 step 1, 5; components.md MainWindow Incognito state, tokens.md §1.4; Claude incognito
// reference P7): a solid 2 pt `incognito.frame` border just inside the window while it shows an incognito chat.
// Plus the window-level guards that need the NSWindow:
//   - `isRestorable = false` while incognito (no Saved Application State for it; guard 10);
//   - closing the window (⌘W, the close button) with an incognito chat that has messages asks first
//     (`WindowState.requestCloseWindow`): a delegate proxy answers `windowShouldClose` and forwards every other
//     delegate message to SwiftUI's own delegate;
//   - quitting (`IncognitoQuitGuard`, called from the app delegate) asks the same question in the window.
import AntiChatDesign
import AntiChatHarness
import AppKit
import SwiftUI

extension View {
    /// The incognito border and window guards for `state`'s window.
    func incognitoFrame(_ state: WindowState) -> some View {
        modifier(IncognitoFrameModifier(state: state))
    }
}

/// Test hook: a hosted window in a test process has no running NSApp, and ending a SwiftUI alert sheet there
/// enqueues a CFRunLoopStop on the main run loop; unless a nested run absorbs it, it ends the test process's main
/// loop (the process exits 0 mid-run). The in-process journey turns the alert off for its whole run and drives
/// `WindowState` directly; the app never changes it.
@MainActor
enum IncognitoConfirmation {
    static var presentsAlert = true
}

struct IncognitoFrameModifier: ViewModifier {
    let state: WindowState

    func body(content: Content) -> some View {
        content
            .overlay {
                if state.isIncognito {
                    Rectangle()
                        .strokeBorder(Color.incognitoFrame, lineWidth: 2)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .probeID("incognitoFrame")
                }
            }
            .background(WindowGuardAnchor(state: state, incognito: state.isIncognito))
            .alert(Text(CopyKey("incognito.close.confirm")),
                   isPresented: Binding(get: { state.pendingIncognitoLeave != nil && IncognitoConfirmation.presentsAlert },
                                        set: { if !$0, state.pendingIncognitoLeave != nil { state.cancelIncognitoLeave() } })) {
                Button(role: .destructive) { state.confirmIncognitoLeave() } label: { Text(CopyKey("incognito.close.cta")) }
                    .accessibilityIdentifier("incognito.close.cta")
                Button(role: .cancel) { state.cancelIncognitoLeave() } label: { Text(CopyKey("row.delete.cancel")) }
                    .accessibilityIdentifier("row.delete.cancel")
            }
    }
}

/// Finds the hosting NSWindow and keeps the guards installed on it.
private struct WindowGuardAnchor: NSViewRepresentable {
    let state: WindowState
    let incognito: Bool

    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ view: GuardView, context: Context) {
        view.state = state
        view.incognito = incognito
        view.apply()
    }

    final class GuardView: NSView {
        weak var state: WindowState?
        var incognito = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, let state else { return }
            state.window = window  // M1.T24
            window.isRestorable = IncognitoGuards.windowIsRestorable(showingIncognito: incognito)
            WindowCloseGuard.install(on: window, state: state)
            IncognitoQuitGuard.register(state)
        }
    }
}

/// `windowShouldClose` proxy: asks `WindowState` first, then SwiftUI's delegate; forwards everything else.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: (any NSWindowDelegate)?
    weak var state: WindowState?
    /// Set while a confirmed close runs (the guard lets it through).
    var bypass = false

    private static var guards: [ObjectIdentifier: WindowCloseGuard] = [:]

    static func install(on window: NSWindow, state: WindowState) {
        let key = ObjectIdentifier(window)
        let g = guards[key] ?? WindowCloseGuard()
        guards[key] = g
        g.state = state
        if window.delegate !== g {
            g.original = window.delegate
            window.delegate = g
        }
        state.closeWindow = { [weak window, weak g] in
            guard let window, let g else { return }
            g.bypass = true
            window.performClose(nil)
            g.bypass = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !bypass, let state, !state.requestCloseWindow() { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        state?.discardIncognito()
        if let w = notification.object as? NSWindow { Self.guards[ObjectIdentifier(w)] = nil }
        original?.windowWillClose?(notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Quit with an incognito chat that has messages (step 5): the app delegate's `applicationShouldTerminate` calls
/// `reply`; the confirmation shows in that window and answers the held quit.
@MainActor
public enum IncognitoQuitGuard {
    final class Box { weak var state: WindowState?; init(_ s: WindowState) { state = s } }
    private static var windows: [Box] = []

    /// Every live main window's state (M1.T24: the menus' fallback target).
    static var states: [WindowState] { windows.compactMap(\.state) }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// The live main windows' states (in-process probes: ⇧⌘N opens a new incognito window, M1.T24).
    public static var liveStates: [WindowState] { states }
    #endif

    static func register(_ state: WindowState) {
        windows.removeAll { $0.state == nil }
        if !windows.contains(where: { $0.state === state }) { windows.append(Box(state)) }
    }

    /// `.terminateNow` when no window holds incognito messages (empty sessions are discarded), else
    /// `.terminateLater` with the confirmation showing in the first such window. `only` limits the check to the given
    /// windows (tests: the registry is process-wide, and answering another test's window would quit the process).
    public static func reply(_ app: NSApplication?, only: [WindowState]? = nil) -> NSApplication.TerminateReply {
        let states = only ?? windows.compactMap(\.state)
        guard let held = states.first(where: { $0.hasIncognitoContent }) else {
            for s in states { s.discardIncognito() }
            return .terminateNow
        }
        held.answerQuit = { [weak app] quit in
            if quit {
                for s in states where s !== held { s.discardIncognito() }
            }
            app?.reply(toApplicationShouldTerminate: quit)
        }
        _ = held.requestQuit()
        return .terminateLater
    }

    /// Every open incognito session is discarded (app teardown, `applicationWillTerminate`).
    public static func discardAll() {
        for s in windows.compactMap(\.state) { s.discardIncognito() }
    }
}
