// Edit a message (M1.T10 step 6; R-006 AC1–2; IS-11; ChatGPT FL-13): the edited prompt is a new *sibling* user
// node (version n+1 of that turn) answered by a new assistant reply; the original user message and its whole
// branch stay intact, reachable through ‹ n/N › on the user bubble.
//
// Attachments (known failure mode in M1.T10): the new sibling gets copies of the original's `attachment` rows that
// the editor kept (same `blob_id`, no file copy); removing one in the editor drops it from the new version only.
import AntiChatStorage
import Foundation
import GRDB

public struct EditService: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// The request that sends `text` as a new version of `userID`, keeping `keptAttachmentIDs` (nil = all).
    public static func request(
        userID: String, newUserID: String, text: String, keptAttachmentIDs: [String]? = nil
    ) -> TurnRequest {
        .edit(userID: userID, newUserID: newUserID, text: text, attachmentIDs: keptAttachmentIDs)
    }

    /// The attachments the inline editor shows above the field (in attach order).
    public func attachments(of messageID: String) throws -> [AttachmentRecord] {
        try AttachmentRepository(database).attachments(messageID: messageID)
    }

    /// A message's attachments with their blobs, inside the caller's transaction (the transcript load).
    public static func attachments(of messageID: String, db: Database) throws -> [(AttachmentRecord, FileBlobRecord?)] {
        try AttachmentRecord.filter(Column("message_id") == messageID).order(Column("created_at")).fetchAll(db).map {
            ($0, try FileBlobRecord.fetchOne(db, key: $0.blobID))
        }
    }

    /// M6.T01: attachment rows by id with their blobs, in the order of `ids` (the composer tray's order).
    public static func attachments(ids: [String], db: Database) throws -> [(AttachmentRecord, FileBlobRecord?)] {
        let rows = try AttachmentRecord.filter(ids.contains(Column("id"))).fetchAll(db)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return try ids.compactMap { byID[$0] }.map { ($0, try FileBlobRecord.fetchOne(db, key: $0.blobID)) }
    }

    /// Copies `from`'s attachment rows (those in `keep`, or all when nil) onto `to`: new ids, same blobs, same
    /// order. Runs inside the turn's write transaction.
    @discardableResult
    public static func carryAttachments(from source: String, to target: String, keep: [String]?, db: Database) throws -> [String] {
        let rows = try AttachmentRecord.filter(Column("message_id") == source).order(Column("created_at")).fetchAll(db)
        var copied: [String] = []
        for var row in rows where keep?.contains(row.id) ?? true {
            row.id = StorageID.make()
            row.messageID = target
            try row.insert(db)
            copied.append(row.id)
        }
        return copied
    }
}
