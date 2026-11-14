// Follow-ups while generating (M1.T19 step 6, R-014, IS-5 "Queue" default): Return during a reply queues the
// message as a pending bubble (editable, removable ×) that is sent when the turn ends, in order; ⌘Return sends now:
// the running reply is stopped first (interrupted notice on it), then the message goes out. Pure value type; the
// chat's view model owns one and drains it on every turn end.
import Foundation

/// A message waiting to be sent (a follow-up behind the running reply).
public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// The composer's paste cards (plain text), saved with the message when it is sent.
    public var pastedTexts: [String]
    /// M6.T01: file attachments (`attachment` row ids written by intake), linked to the message when it is sent.
    public var fileIDs: [String]
    public var queuedAt: Date

    public init(id: String = UUID().uuidString, text: String, pastedTexts: [String] = [], fileIDs: [String] = [],
                queuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.pastedTexts = pastedTexts
        self.fileIDs = fileIDs
        self.queuedAt = queuedAt
    }

    /// Something to send (text, a paste card or a file).
    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pastedTexts.isEmpty || !fileIDs.isEmpty
    }
}

public struct FollowUpQueue: Sendable, Hashable {
    /// What a send does while a reply is running.
    public enum Action: Sendable, Hashable {
        /// Nothing runs: send at once.
        case send
        /// Return during generation: queue behind the reply.
        case enqueue
        /// ⌘Return during generation: stop the reply, then send.
        case sendNow
    }

    /// Return (`sendNow == false`) or ⌘Return (`true`) while the chat is (or is not) generating.
    public static func action(generating: Bool, sendNow: Bool) -> Action {
        guard generating else { return .send }
        return sendNow ? .sendNow : .enqueue
    }

    public private(set) var items: [QueuedMessage] = []

    public init(items: [QueuedMessage] = []) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Appends a message (trimmed). Returns nil when there is nothing to send.
    @discardableResult
    public mutating func enqueue(_ text: String, pastedTexts: [String] = [], fileIDs: [String] = [],
                                 at date: Date = Date()) -> QueuedMessage? {
        let m = QueuedMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines), pastedTexts: pastedTexts,
                              fileIDs: fileIDs, queuedAt: date)
        guard m.hasContent else { return nil }
        items.append(m)
        return m
    }

    /// Edits a queued message in place (its position is kept). An edit that leaves nothing to send removes it.
    @discardableResult
    public mutating func edit(_ id: String, text: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !items[i].hasContent { items.remove(at: i) }
        return true
    }

    /// The × on a queued bubble: it is never sent.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: i)
        return true
    }

    /// The next message to send when a turn ends (oldest first).
    public mutating func popNext() -> QueuedMessage? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }
}
