// ⌘K chat search for the palette (M1.T11, R-012): `ChatListService` wraps Storage's `FTSSearch` and hands the UI
// plain value types (the UI reaches chats only through this service, A-M1-T07a d).
import AntiChatStorage
import Foundation

/// One chat in the ⌘K results.
public struct ChatSearchHit: Identifiable, Hashable, Sendable {
    /// One run of the excerpt; `isMatch` runs are highlighted.
    public struct Run: Hashable, Sendable {
        public var text: String
        public var isMatch: Bool
        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public var id: String { chatID }
    public var chatID: String
    /// Empty while the auto title is pending (the row shows `side.untitled`).
    public var title: String
    public var isEvil: Bool
    public var archived: Bool
    public var updatedAt: Date
    public var titleMatched: Bool
    /// The best-matching message (open the chat at it; M1.T10 scroll-to-message).
    public var messageID: String?
    /// The excerpt of that message, split into highlighted / plain runs (empty for a title-only match).
    public var excerpt: [Run]

    public init(chatID: String, title: String, isEvil: Bool = false, archived: Bool = false, updatedAt: Date = Date(),
                titleMatched: Bool = false, messageID: String? = nil, excerpt: [Run] = []) {
        self.chatID = chatID
        self.title = title
        self.isEvil = isEvil
        self.archived = archived
        self.updatedAt = updatedAt
        self.titleMatched = titleMatched
        self.messageID = messageID
        self.excerpt = excerpt
    }

    init(_ h: FTSSearch.Hit) {
        self.init(chatID: h.chatID, title: h.title, isEvil: h.isEvil, archived: h.archived, updatedAt: h.updatedAt,
                  titleMatched: h.titleMatched, messageID: h.messageID,
                  excerpt: h.snippet?.runs.map { Run(text: $0.text, isMatch: $0.isMatch) } ?? [])
    }

    /// The excerpt as plain text.
    public var excerptText: String { excerpt.map(\.text).joined() }
}

public extension ChatListService {
    /// A database file at `url` (benchmarks and tools on a fixture database; the app uses `ChatEnvironment`).
    static func onDisk(at url: URL) throws -> ChatListService {
        ChatListService(database: try AppDatabase.onDisk(at: url))
    }

    /// Full-text search over every local chat's title and message bodies (bm25; NFR-U10). Thread-safe: the palette
    /// runs it off the main actor. `likedOnly` = the ⌘K Liked filter (replies rated 👍).
    func search(_ query: String, limit: Int = 30, likedOnly: Bool = false) throws -> [ChatSearchHit] {
        try FTSSearch(database).search(query, limit: limit, likedOnly: likedOnly).map(ChatSearchHit.init)
    }

    /// The palette's empty-query list: recent chats, or the chats of recently liked replies.
    func recentChats(limit: Int = 8, likedOnly: Bool = false) throws -> [ChatSearchHit] {
        try FTSSearch(database).recents(limit: limit, likedOnly: likedOnly).map(ChatSearchHit.init)
    }
}
