// Message feedback (S-09: local only, never sent). Liked and disliked are exclusive; refused/report are flags.
import Foundation
import GRDB

public struct FeedbackRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public enum Rating: String, Sendable { case liked, disliked }

    /// Sets the 👍/👎 rating of a message (nil clears it).
    public func setRating(_ messageID: String, _ rating: Rating?, note: String? = nil) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM feedback WHERE message_id = ? AND kind IN ('liked', 'disliked')",
                           arguments: [messageID])
            if let rating, let kind = FeedbackKind(rawValue: rating.rawValue) {
                try FeedbackRecord(messageID: messageID, kind: kind, note: note).insert(db)
            }
        }
    }

    public func rating(_ messageID: String) throws -> Rating? {
        try database.read { db in try Self.rating(messageID, db: db) }
    }

    /// The rating inside the caller's transaction (the transcript load reads it per message, M1.T10).
    public static func rating(_ messageID: String, db: Database) throws -> Rating? {
        try String.fetchOne(db, sql: """
            SELECT kind FROM feedback WHERE message_id = ? AND kind IN ('liked', 'disliked')
            """, arguments: [messageID]).flatMap(Rating.init(rawValue:))
    }

    /// Records a `refused` / `report` flag (replacing an earlier one of the same kind).
    public func flag(_ messageID: String, _ kind: FeedbackKind, note: String? = nil) throws {
        try database.write { db in try FeedbackRecord(messageID: messageID, kind: kind, note: note).save(db) }
    }

    public func feedback(_ messageID: String) throws -> [FeedbackRecord] {
        try database.read { db in try FeedbackRecord.filter(Column("message_id") == messageID).fetchAll(db) }
    }

    /// Message ids rated `liked` (⌘K "Liked" filter, AT-005 leg 4).
    public func likedMessageIDs() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT message_id FROM feedback WHERE kind = 'liked' ORDER BY created_at DESC")
        }
    }
}
