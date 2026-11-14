// Attachment + file_blob rows (architecture §5.1). M1.T08: pasted-text cards (`PastedTextAttachmentStore` in
// Harness writes the bytes, this inserts the rows). File intake (C-018, M5) extends it.
import Foundation
import GRDB

public struct AttachmentRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// Inserts an attachment for a blob, reusing the `file_blob` row with the same sha256 (the column is unique).
    /// One transaction.
    @discardableResult
    public func insert(sha256: String, size: Int64, path: String, origin: BlobOrigin, messageID: String?,
                       displayName: String, uti: String, now: Date = Date()) throws -> AttachmentRecord {
        try database.write { db in
            let blob: FileBlobRecord
            if let existing = try FileBlobRecord.filter(Column("sha256") == sha256).fetchOne(db) {
                blob = existing
            } else {
                blob = FileBlobRecord(sha256: sha256, size: size, path: path, createdAt: now, origin: origin)
                try blob.insert(db)
            }
            let attachment = AttachmentRecord(messageID: messageID, blobID: blob.id, displayName: displayName,
                                              uti: uti, createdAt: now)
            try attachment.insert(db)
            return attachment
        }
    }

    public func blob(id: String) throws -> FileBlobRecord? {
        try database.read { db in try FileBlobRecord.fetchOne(db, key: id) }
    }

    public func attachments(messageID: String) throws -> [AttachmentRecord] {
        try database.read { db in
            try AttachmentRecord.filter(Column("message_id") == messageID).order(Column("created_at")).fetchAll(db)
        }
    }
}
