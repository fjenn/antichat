// M2.T24 step 3 (R-238 AC2): the media requests waiting for their pack, per chat (`pending_request`, v12). The card's
// turn (assistant message) stores the user message it answers; once the pack is verified the chat re-runs that
// request as a new version of the reply, with no extra user action, and the row is removed. Rows of a deleted chat
// or message go with it (ON DELETE CASCADE). Incognito chats are in-memory databases, so nothing outlives them.
import AntiChatStorage
import Foundation
import GRDB

public struct PendingRequest: Sendable, Hashable {
    public var assistantID: String
    public var chatID: String
    public var userMessageID: String
    public var pack: MediaPack
    public var createdAt: Date
}

public struct PendingRequestStore: Sendable {
    public let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func add(_ r: PendingRequest) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO pending_request (assistant_id, chat_id, user_message_id, pack, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [r.assistantID, r.chatID, r.userMessageID, r.pack.rawValue, r.createdAt.timeIntervalSince1970])
        }
    }

    public func pending(chatID: String) -> [PendingRequest] {
        (try? database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_request WHERE chat_id = ? ORDER BY created_at", arguments: [chatID])
                .compactMap { row -> PendingRequest? in
                    guard let pack = MediaPack(rawValue: row["pack"]) else { return nil }
                    return PendingRequest(assistantID: row["assistant_id"], chatID: row["chat_id"],
                                          userMessageID: row["user_message_id"], pack: pack,
                                          createdAt: Date(timeIntervalSince1970: row["created_at"]))
                }
        }) ?? []
    }

    public func remove(assistantID: String) {
        _ = try? database.write { db in try db.execute(sql: "DELETE FROM pending_request WHERE assistant_id = ?", arguments: [assistantID]) }
    }
}
