// Completion (M1.T19 step 5, IS-4, AT-003 (4)): when a reply ends, every completion-state change happens together,
// in one transition — the ActionBar fades in, Stop turns back into Send, the transient status line vanishes,
// activity lines collapse, the sidebar spinner stops and a ready title is applied. The chat's view model applies its
// own state and then the coordinator runs every registered handler (composer, sidebar, title, unread) in the same
// synchronous main-actor pass, so SwiftUI commits them in one transaction (one frame). One `turnCompletion`
// signpost per completion (perf log: `ANTICHAT_PERF_LOG`).
import AntiChatFoundation
import AntiChatStorage
import Foundation

/// One finished turn as the window sees it.
public struct TurnCompletion: Sendable, Hashable {
    public var chatID: String
    public var assistantID: String
    public var status: MessageStatus
    /// The chat was on screen in this window when the reply ended (else it is marked unread).
    public var visible: Bool

    public init(chatID: String, assistantID: String, status: MessageStatus, visible: Bool) {
        self.chatID = chatID
        self.assistantID = assistantID
        self.status = status
        self.visible = visible
    }
}

@MainActor
public final class CompletionCoordinator {
    public typealias Handler = @MainActor (TurnCompletion) -> Void

    private var handlers: [(id: UUID, run: Handler)] = []
    /// Completions handled so far (newest last, at most 64; tests and probes).
    public private(set) var history: [TurnCompletion] = []

    public init() {}

    /// Adds a handler run inside every completion pass, in registration order. Returns its token.
    @discardableResult
    public func register(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers.append((id, handler))
        return id
    }

    public func unregister(_ id: UUID) { handlers.removeAll { $0.id == id } }

    /// `apply` (the chat's own changes: message status, phase, live reply) and then every handler, synchronously,
    /// in one main-actor pass.
    public func complete(_ completion: TurnCompletion, apply: () -> Void) {
        let state = Signposts.begin(.turnCompletion, on: Signposts.ui)
        apply()
        for h in handlers { h.run(completion) }
        Signposts.end(.turnCompletion, state, on: Signposts.ui)
        history.append(completion)
        if history.count > 64 { history.removeFirst(history.count - 64) }
    }
}
