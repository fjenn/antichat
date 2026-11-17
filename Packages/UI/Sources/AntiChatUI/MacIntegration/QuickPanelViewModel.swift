// M8.T13 steps 4 (R-106 AC1; S-22): the quick panel's state machine. Return sends (the panel's chat is a normal
// chat row, created on the first send, titled like any chat); the reply streams in the panel, which grows to
// 640×480 and scrolls. Esc: while the reply streams, hides the panel (the answer goes on in the background chat);
// with a finished reply on screen, the first Esc collapses the reply area and the second hides the panel; with
// nothing on screen, hides it. "Open in AntiChat" (⌘O) hands the chat — the same conversation, still streaming if
// it is — to the main window and hides the panel. Mode: Normal; Evil only when picked in the panel's ModeSwitch
// (the composer's rules: shown only while Evil Mode is on and not hidden).
import AntiChatDesign
import Foundation
import Observation

/// What the panel needs from the app (live: a headless ChatSessions + the main windows; tests: a fake).
@MainActor
public protocol QuickPanelBackend: AnyObject {
    /// Starts a turn in `chatID` (nil = create the chat first); returns the chat id, or nil when nothing was sent.
    func send(_ text: String, chatID: String?, mode: ComposerChatMode) -> String?
    /// The reply shown in the panel for `chatID` (the last assistant message) and whether it is still streaming.
    func reply(chatID: String) -> (text: String, streaming: Bool)
    /// Stops `chatID`'s streaming reply (the panel's stop button; the chat keeps what streamed so far).
    func stop(chatID: String)
    /// Moves `chatID` to a main window (opening one when none is on screen); the conversation keeps streaming.
    func openInApp(chatID: String)
    /// Evil Mode's switch is offered (on and not hidden).
    var offersEvil: Bool { get }
}

@MainActor @Observable
public final class QuickPanelViewModel {
    public enum Phase: String, Sendable { case empty, streaming, done }
    public enum EscapeResult: String, Sendable { case hidePanel, collapsedReply }

    public static let compactSize = CGSize(width: 640, height: 120)
    public static let expandedSize = CGSize(width: 640, height: 480)

    public var text = ""
    public var mode: ComposerChatMode = .normal
    /// The panel's chat (nil until the first send, and again after a collapse).
    public private(set) var chatID: String?
    /// The reply area is shown.
    public private(set) var showsReply = false
    /// The question the shown reply answers (echoed above it, as in the chat column).
    public private(set) var prompt = ""
    @ObservationIgnored public weak var backend: (any QuickPanelBackend)?
    /// The panel asks its window to hide (set by QuickPanelController).
    @ObservationIgnored public var hide: (@MainActor () -> Void)?
    /// Bumped to re-focus the text field.
    public private(set) var focusRequest = 0

    public init(backend: (any QuickPanelBackend)? = nil) { self.backend = backend }

    public var reply: (text: String, streaming: Bool) { chatID.flatMap { backend?.reply(chatID: $0) } ?? ("", false) }

    public var phase: Phase {
        guard showsReply, chatID != nil else { return .empty }
        return reply.streaming ? .streaming : .done
    }

    /// The reply area's measured content height (question + answer + padding), reported by the view.
    public var replyContentHeight: CGFloat = 0
    /// The fixed parts around the reply: the field row (80), the divider and the "Open in AntiChat" row.
    static let replyChrome: CGFloat = 80 + 1 + 44
    public static let minimumExpandedHeight: CGFloat = 200

    /// VQ (S-22): with a reply the panel fits its content — at least 200 pt, at most `expandedSize` (then it scrolls).
    public var size: CGSize {
        guard showsReply else { return Self.compactSize }
        let fit = (Self.replyChrome + replyContentHeight).rounded(.up)
        return CGSize(width: Self.expandedSize.width,
                      height: min(Self.expandedSize.height, max(Self.minimumExpandedHeight, fit)))
    }
    public var offersEvil: Bool { backend?.offersEvil ?? false }

    /// Return. A follow-up goes to the same chat while its reply is on screen.
    @discardableResult
    public func send() -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, phase != .streaming, let backend else { return false }
        if !offersEvil { mode = .normal }
        guard let id = backend.send(body, chatID: showsReply ? chatID : nil, mode: mode) else { return false }
        chatID = id
        showsReply = true
        prompt = body
        text = ""
        return true
    }

    /// Stop while the reply streams: the turn ends where it is; the panel keeps the partial answer (Esc collapses).
    @discardableResult
    public func stop() -> Bool {
        guard phase == .streaming, let id = chatID, let backend else { return false }
        backend.stop(chatID: id)
        focusRequest &+= 1
        return true
    }

    /// Esc (see the file header).
    @discardableResult
    public func escape() -> EscapeResult {
        switch phase {
        case .streaming:
            hide?()
            return .hidePanel
        case .done:
            collapse()
            return .collapsedReply
        case .empty:
            hide?()
            return .hidePanel
        }
    }

    /// The × button: the panel hides as it is (the typed text stays; a streaming reply goes on).
    public func close() { hide?() }

    /// ⌘O: the main window takes the chat (nil when there is none yet).
    @discardableResult
    public func openInApp() -> String? {
        guard let id = chatID, let backend else { return nil }
        backend.openInApp(chatID: id)
        collapse()
        hide?()
        return id
    }

    /// The panel was shown again: an idle panel starts fresh; a streaming one keeps its reply.
    public func shown() {
        if phase == .done { collapse() }
        focusRequest &+= 1
    }

    private func collapse() {
        showsReply = false
        replyContentHeight = 0
        chatID = nil
        prompt = ""
        mode = .normal
        focusRequest &+= 1
    }
}
