// Composer drafts (R-302, P-shell-15): one row per chat id or `new`. The caller debounces (500 ms); incognito
// drafts go to the in-memory database, so they never reach disk.
import Foundation
import GRDB

public struct DraftRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// Saves (or, for empty text and no attachments, clears) the draft of `chatID`.
    public func save(chatID: String, text: String, attachmentsJSON: String? = nil) throws {
        try database.write { db in
            if text.isEmpty && (attachmentsJSON ?? "").isEmpty {
                _ = try DraftRecord.deleteOne(db, key: chatID)
            } else {
                try DraftRecord(chatID: chatID, text: text, attachmentsJSON: attachmentsJSON).save(db)
            }
        }
    }

    public func draft(chatID: String) throws -> DraftRecord? {
        try database.read { db in try DraftRecord.fetchOne(db, key: chatID) }
    }

    public func delete(chatID: String) throws {
        _ = try database.write { db in try DraftRecord.deleteOne(db, key: chatID) }
    }

    /// Moves the `new` draft to a chat that was just created from it.
    public func adoptNewDraft(into chatID: String) throws {
        try database.write { db in
            guard var draft = try DraftRecord.fetchOne(db, key: DraftRecord.newChatKey) else { return }
            _ = try DraftRecord.deleteOne(db, key: DraftRecord.newChatKey)
            draft.chatID = chatID
            try draft.save(db)
        }
    }
}
