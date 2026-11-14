// Regenerate with versions (M1.T10 steps 2–3; R-005; IS-11; P-shell-03 tree ops from M1.T04).
//
// A regenerate is a `TurnRequest.retry` whose new assistant node is a sibling of the old one (version n+1, made
// active by `MessageTree.append`). The Try again popover's "Ask to change response" text is a *volatile* steering
// instruction: it is appended to the request's last user turn for that one request and never stored as a message,
// so the stored conversation (and the next turn's cached prefix) is unchanged. "Think harder" turns reasoning on
// for that request (M1.T15 owns the budget and the reasoning display).
//
// Versions of a turn are the siblings of a message (same parent, ordered by `position`); switching versions only
// moves `active_child_id` (and the leaf follows), so every version keeps the branch below it.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

/// How a regenerate runs (the Try again popover / the 👎 menu).
public struct RegenerateOptions: Sendable, Hashable {
    /// "Ask to change response": appended to this request only (never stored). nil/blank = plain regenerate.
    public var steering: String?
    /// "Think harder": reasoning on for this request.
    public var thinkHarder: Bool

    public init(steering: String? = nil, thinkHarder: Bool = false) {
        let s = steering?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.steering = (s?.isEmpty ?? true) ? nil : s
        self.thinkHarder = thinkHarder
    }
}

/// One version of a turn (a sibling), for the version switcher and the Versions viewer.
public struct MessageVersion: Sendable, Hashable, Identifiable {
    public var id: String
    /// 1-based position among the siblings.
    public var index: Int
    public var total: Int
    public var role: MessageRole
    public var createdAt: Date
    public var status: MessageStatus
    /// Text parts joined (the Versions viewer shows it).
    public var text: String
    /// The version's reply (for a user version: its active assistant child), so the viewer can show the full turn.
    public var replyText: String?
    /// On the visible path now.
    public var isActive: Bool
}

public struct RegenerateService: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// The request for a regenerate of `assistantID` (its reply becomes version n+1).
    public static func request(_ assistantID: String, options: RegenerateOptions = RegenerateOptions()) -> TurnRequest {
        .retry(assistantID: assistantID, options: options)
    }

    // MARK: Versions

    /// Every version of the turn `messageID` belongs to (its siblings, by position), with their texts.
    public func versions(of messageID: String) throws -> [MessageVersion] {
        try database.read { db in try Self.versions(of: messageID, db: db) }
    }

    public static func versions(of messageID: String, db: Database) throws -> [MessageVersion] {
        let siblings = try MessageTree.siblings(of: messageID, db: db)
        let target = try MessageTree.message(messageID, db: db)
        let activeID: String? = try {
            if let parent = target.parentID { return try MessageTree.message(parent, db: db).activeChildID }
            // Sibling roots: the active one is on the visible path.
            let path = try MessageTree.visiblePath(target.chatID, db: db)
            return path.first?.id
        }()
        return try siblings.enumerated().map { i, m in
            var reply: String?
            if m.role == .user, let child = m.activeChildID {
                reply = try text(of: child, db: db)
            }
            return MessageVersion(
                id: m.id, index: i + 1, total: siblings.count, role: m.role, createdAt: m.createdAt, status: m.status,
                text: try text(of: m.id, db: db), replyText: reply, isActive: m.id == activeID)
        }
    }

    /// Makes `messageID` the visible version of its turn (VersionSwitcher ‹ ›, Versions viewer "select").
    public func select(_ messageID: String) throws {
        try MessageTree(database).setActive(messageID)
    }

    /// The sibling `delta` steps from `messageID` (‹ = -1, › = +1), made visible; nil at either end.
    @discardableResult
    public func step(from messageID: String, by delta: Int) throws -> String? {
        try database.write { db in
            let siblings = try MessageTree.siblings(of: messageID, db: db)
            guard let i = siblings.firstIndex(where: { $0.id == messageID }) else { return nil }
            let j = i + delta
            guard siblings.indices.contains(j) else { return nil }
            try MessageTree.setActive(siblings[j].id, db: db)
            return siblings[j].id
        }
    }

    // MARK: Request shaping

    /// The volatile steering line (fixed English, like the date line: the model reads it, the user never sees it).
    public static func steeringInstruction(_ text: String) -> String {
        "Instruction for this answer only: \(text)"
    }

    /// The prompt with the steering instruction appended to its last user turn (or as a trailing user turn).
    public static func steer(_ prompt: [ChatMessage], with steering: String?) -> [ChatMessage] {
        guard let steering, !steering.isEmpty else { return prompt }
        var out = prompt
        let line = steeringInstruction(steering)
        if let last = out.indices.last, out[last].role == .user {
            let body = out[last].content
            out[last].content = body.isEmpty ? line : body + "\n\n" + line
        } else {
            out.append(ChatMessage(role: .user, content: line))
        }
        return out
    }

    /// The request's reasoning options (Think harder → on; the budget is M1.T15's).
    public static func reasoning(for options: RegenerateOptions) -> ReasoningOptions {
        options.thinkHarder ? ReasoningOptions(on: true) : .off
    }

    private static func text(of id: String, db: Database) throws -> String {
        try MessageRepository.parts(of: id, db: db).filter { $0.kind == .text }.map(\.body).joined()
    }
}
