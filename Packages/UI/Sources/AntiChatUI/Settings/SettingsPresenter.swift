// Where Settings is shown (owner 2026-11-16: "it should just be in the app itself", not a window of its own).
// Settings is a full-window view over the chat, inside a main window (`MainWindow.settingsOverlay`): the chat under it
// stays as it is (draft, scroll position, a streaming answer) and comes back on "Back to chat" / Esc.
// Every way in goes through `show`: ⌘, and AntiChat › Settings… (`SettingsCommands`), the sidebar's Settings button,
// the links that open a page or a row (composer, cards, pills, banners), the menu bar item and notifications.
// One Settings at a time, in the key main window; with no main window on screen one is opened first.
import AppKit
import Observation

@MainActor
@Observable
public final class SettingsPresenter {
    public static let shared = SettingsPresenter()

    /// The window showing Settings (nil: closed).
    public private(set) var hostID: ObjectIdentifier?
    @ObservationIgnored private weak var host: WindowState?
    /// What had the keyboard focus in the window (the composer, usually); it gets it back on close.
    @ObservationIgnored private weak var previousResponder: NSResponder?
    /// `show` was called with no main window on screen; the next window to appear shows Settings.
    @ObservationIgnored private var pending = false
    /// Opens a main window (the app sets it: File › New Window when none is on screen).
    @ObservationIgnored public var openWindow: (@MainActor () -> Void)?

    public init() {}

    public var isShown: Bool { hostID != nil }

    public func isShown(in state: WindowState) -> Bool { hostID == ObjectIdentifier(state) }

    /// Shows Settings in the key main window, on `section` (and `row`) when given, else on the page a caller asked
    /// for through `SettingsNavigator`, else where it was left.
    public func show(_ section: SettingsSection? = nil, row: String? = nil) {
        if let section { SettingsNavigator.shared.request(section, row: row) }
        guard let target = Self.target() else {
            pending = true
            openWindow?()
            return
        }
        present(in: target)
    }

    /// Shows Settings in `state`'s window (the window's own Settings button; tests).
    public func present(in state: WindowState) {
        pending = false
        let window = state.window
        if hostID != ObjectIdentifier(state) {
            previousResponder = window?.firstResponder.flatMap { $0 === window ? nil : $0 }
        }
        host = state
        hostID = ObjectIdentifier(state)
        SettingsModel.shared.consume()
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isKeyWindow, (NSApp as NSApplication?)?.isActive == true { BackgroundRun.makeKeyAndOrderFront(window) }
        window.makeFirstResponder(nil)  // typing no longer lands in the composer under Settings
    }

    /// Back to the chat: the window is as it was, and the keyboard focus returns to where it was.
    public func dismiss() {
        guard hostID != nil else { return }
        let window = host?.window, responder = previousResponder
        hostID = nil
        host = nil
        previousResponder = nil
        // After the chat is enabled again (a disabled text view refuses the focus).
        DispatchQueue.main.async {
            guard let window, let view = responder as? NSView, view.window === window,
                  window.firstResponder === window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// A main window came on screen: it shows Settings when `show` was waiting for one.
    func windowAppeared(_ state: WindowState) {
        if pending { present(in: state) }
    }

    /// A main window went away (its identifier may be reused).
    func windowDisappeared(_ state: WindowState) {
        if hostID == ObjectIdentifier(state) { dismiss() }
    }

    /// The key (else main, else front-most visible, else a minimised) main window.
    private static func target() -> WindowState? {
        guard (NSApp as NSApplication?) != nil else { return nil }  // a headless process
        if let s = MenuTarget.frontmost(nil) { return s }
        return IncognitoQuitGuard.states.first { $0.window?.isMiniaturized == true }
    }
}
