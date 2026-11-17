// M8.T13 steps 2–5 (R-106, NFR-U9; components.md QuickPanel, S-22). One non-activating floating `NSPanel`
// ([.borderless, .nonactivatingPanel, .fullSizeContentView], level .floating, all Spaces + full-screen auxiliary,
// moved by its background), 640×120, hosting `QuickPanelView`. It is created hidden after the main
// window's first paint + 1 s, so opening is only orderFrontRegardless + makeKey + the text field as first responder
// (an AppKit NSTextField, made first responder synchronously). The panel's chats run on a headless ChatSessions
// (`LiveQuickPanelBackend`): a hidden panel's reply keeps streaming, and "Open in AntiChat" hands the very same
// ConversationModel to a main window (no restart).
//
// Closing (owner 2026-11-16: "there's no easy way to close the quick panel"): the panel floats over every app and
// Space, and it used to stay there once the keyboard focus had left it — Esc only reached it while its text field had
// the focus, a click elsewhere left it up, and ⌥Space on a panel that was no longer key focused it again instead of
// hiding it. Now Esc is taken by the window whatever has the focus inside it, a click anywhere outside (another app,
// the desktop, an AntiChat window: the panel stops being key, or a mouse-down lands outside it) hides it, ⌥Space on a
// visible panel always hides it, and the panel has a small × button. Hiding never clears the typed text.
//
// NFR-U9 (`quickPanelOpen`): from the trigger (the hotkey handler's entry, or the poster's timestamp carried by the
// DEBUG `-QuickPanelHotkeyHook` notification) until the text field is first responder and the panel has been
// displayed (the CATransaction commit after `display`). Recorded through `Signposts.mark` (perf log + signpost).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AppKit
import Defaults
import QuartzCore
import SwiftUI

/// The panel window: key-capable although non-activating; ⌘O opens the chat in the main window.
final class QuickPanelWindow: NSPanel {
    weak var model: QuickPanelViewModel?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "o" {
            MainActor.assumeIsolated { _ = model?.openInApp() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { _ = model?.escape() }
    }

    /// Esc closes whatever has the focus inside the panel (the field, a button, the reply, nothing). The field's own
    /// handler only ran while its editor was first responder. An input method composing text keeps its Esc.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option]),
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            MainActor.assumeIsolated { _ = model?.escape() }
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
public final class QuickPanelController {
    public static let shared = QuickPanelController()

    /// How the panel was asked for (NFR-U9 `method`).
    public enum Trigger: Sendable, Equatable {
        /// The global hotkey's handler; `at` = handler entry (systemUptime).
        case hotkey(at: TimeInterval)
        /// The DEBUG hook: `at` = the poster's systemUptime just before posting.
        case posted(at: TimeInterval)
        /// The menu bar's Quick Panel item.
        case menu
    }

    public let model = QuickPanelViewModel()
    private(set) var panel: QuickPanelWindow?
    weak var textField: NSTextField?
    private var backend: LiveQuickPanelBackend?
    /// While the panel is shown: mouse-downs outside it (other apps; AntiChat's own windows) hide it.
    private var outsideClickMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// Open durations recorded this run (ms, probe).
    public private(set) var openTimes: [(method: String, ms: Double)] = []

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var window: NSWindow? { panel }
    /// The text field is the panel's first responder (its field editor is).
    public var fieldIsFirstResponder: Bool {
        guard let p = panel, let f = textField else { return false }
        return p.firstResponder === f || (p.firstResponder as? NSText)?.delegate === f
    }
    /// The panel's conversation for `chatID` while the panel still owns it (probe).
    public func conversation(for chatID: String) -> ConversationModel? { backend?.sessions.model(for: chatID) }

    init() {
        model.hide = { [weak self] in self?.hide() }
    }

    /// The app's environment (once, at launch).
    public func install(environment: ChatEnvironment, chats: ChatListService) {
        guard backend == nil, FeatureFlag.quickPanel.isEnabled() else { return }
        let b = LiveQuickPanelBackend(environment: environment, chats: chats) { id, conversation in
            // "Open in AntiChat": a main window takes the same conversation and shows the chat.
            BackgroundRun.activate()
            AppNotifications.withWindow { s in
                s.adoptConversation?(conversation)
                if let w = s.window { BackgroundRun.makeKeyAndOrderFront(w) }
                s.open(.chat(id))
            }
        }
        backend = b
        model.backend = b
        GlobalShortcuts.shared.install { [weak self] trigger in self?.toggle(trigger) }
    }

    /// Creates the panel hidden (after the main window's first paint + 1 s).
    public func prepare() {
        guard panel == nil, backend != nil else { return }
        // Borderless (A-M8-T13a): the frame is exactly the panel (640×120 → 640×480); rounded corners and the
        // material come from the SwiftUI content, the shadow from the window; key-capable via QuickPanelWindow.
        let p = QuickPanelWindow(contentRect: CGRect(origin: .zero, size: QuickPanelViewModel.compactSize),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.setAccessibilityIdentifier("quickPanel")
        p.setAccessibilityTitle(CopyKey("a11y.quickPanel").string())  // M9.T01: announced as "Quick panel"
        p.model = model
        let host = NSHostingView(rootView: QuickPanelView(model: model) { [weak self] field in self?.textField = field }
            .appearanceFromSettings())
        host.sizingOptions = []
        p.contentView = host
        panel = p
        // A click anywhere else takes the key status away: the panel hides (never in a background run, where the
        // panel is never key).
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !BackgroundRun.isOn { self?.hide() } }
        }
        // Lay the view out once now (the text field exists before the first open).
        host.layoutSubtreeIfNeeded()
    }

    /// Hotkey / hook: show when hidden, hide when shown (whether or not the panel still has the keyboard focus).
    public func toggle(_ trigger: Trigger) {
        if isVisible { hide() } else { show(trigger) }
    }

    public func show(_ trigger: Trigger = .menu) {
        if panel == nil { prepare() }
        guard let p = panel else { return }
        model.shown()
        backend?.sessions.currentChatID = model.chatID
        resize(animated: false)
        center(p)
        if BackgroundRun.isOn {
            // Tests / probes: ordered in concealed, never key (a key panel would take the owner's keystrokes).
            BackgroundRun.conceal(p)
            p.orderFrontRegardless()
        } else {
            // Q-015 r4: a hidden app (⌘H) orders no window in, so the hotkey showed nothing while AntiChat was hidden.
            // Unhide without activating: only the panel comes forward, the main window stays where it was.
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            p.orderFrontRegardless()
            p.makeKey()
            watchOutsideClicks()
        }
        if let f = textField { p.makeFirstResponder(f) }
        p.displayIfNeeded()
        let start: TimeInterval?
        let method: String
        switch trigger {
        case .hotkey(let at): start = at; method = "handler-entry"
        case .posted(let at): start = at; method = "posted"
        case .menu: start = nil; method = "menu"
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let start else { return }
                let focused = self.fieldIsFirstResponder
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.openTimes.append((method, ms))
                Signposts.mark(.quickPanelOpen, durationNs: UInt64(max(0, ms) * 1e6), on: Signposts.ui,
                               meta: ["method": method, "focused": focused ? "1" : "0"])
            }
        }
        CATransaction.commit()
    }

    /// A mouse-down outside the panel hides it: in another app (global monitor; mouse events need no permission) or
    /// in one of AntiChat's own windows (local monitor; the event still goes where it was aimed).
    private func watchOutsideClicks() {
        guard outsideClickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { outsideClickMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                // The panel itself and what it opens (a popover: a child window) are inside.
                if let self, let p = self.panel, let window, window !== p, window.parent !== p { self.hide() }
            }
            return event
        }) { outsideClickMonitors.append(m) }
    }

    public func hide() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors = []
        panel?.orderOut(nil)
        // A reply that finishes while the panel is hidden gets its unread dot (review fix).
        backend?.sessions.currentChatID = nil
    }

    /// The panel follows the reply area (640×120 ↔ 640×480), keeping its top edge.
    func resize(animated: Bool) {
        guard let p = panel else { return }
        let size = model.size
        guard p.frame.size != size else { return }
        var f = p.frame
        f.origin.y += f.height - size.height
        f.size = size
        p.setFrame(f, display: true, animate: animated)
    }

    /// Centred horizontally on the screen with the mouse, its top a fifth down (Spotlight's place).
    private func center(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height / 5 - size.height))
    }
}

/// The live backend: a headless ChatSessions (titles, notifications, memory and tools as in any chat) and the
/// app's chat list.
@MainActor
final class LiveQuickPanelBackend: QuickPanelBackend {
    let sessions: ChatSessions
    let chats: ChatListService
    let open: @MainActor (String, ConversationModel) -> Void

    init(environment: ChatEnvironment, chats: ChatListService, openInApp: @escaping @MainActor (String, ConversationModel) -> Void) {
        sessions = ChatSessions(environment: environment)
        self.chats = chats
        open = openInApp
    }

    var offersEvil: Bool { sessions.evil?.showsSwitch ?? false }

    func send(_ text: String, chatID: String?, mode: ComposerChatMode) -> String? {
        do {
            let id = try chatID ?? chats.create(firstPrompt: text).id
            sessions.currentChatID = id
            sessions.composer.mode = mode
            let before = sessions.acceptedSends
            sessions.startTurn(chatID: id, text: text, pastedTexts: [])
            return sessions.acceptedSends > before ? id : (chatID == nil ? id : nil)
        } catch {
            AppLog.log(.ui, .error, "quick panel send: \(error)")
            return nil
        }
    }

    func reply(chatID: String) -> (text: String, streaming: Bool) {
        let m = sessions.model(for: chatID)
        guard let last = m.messages.last(where: { $0.role == .assistant }) else { return ("", m.isGenerating) }
        // While it streams the text collects in the row's LiveReply (flushed at 30 Hz); the message has it at the end.
        let live = m.liveReply(for: last.id)?.text ?? ""
        return (live.isEmpty ? last.text : live, m.isGenerating)
    }

    func stop(chatID: String) { sessions.model(for: chatID).stop() }

    func openInApp(chatID: String) {
        open(chatID, sessions.model(for: chatID))
        sessions.release(chatID)
    }
}
