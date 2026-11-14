// M6.T09 step 9 (R-273, cross-task contract 5): every produced file is one `artifact` with a version chain. The bytes
// go to the media store as `<mediaRoot>/<yyyy>/<sha256>.<ext>` (`file_blob(origin: generated)`, reused by sha256), then
// `artifact` + `artifact_version(n: 1, parent_version_id: NULL)` — or, with `revises`, version n + 1 of that artifact
// (parent = the previous version; T10's VersioningService). Incognito chats write into their session's temp dir,
// removed on discard; a standalone in-memory store gets an `AntiChat-incognito-out-<uuid>` temp dir swept at launch.
// Image refs (`images[].ref`) resolve here too: an attachment id or an artifact id → the stored bytes.
import AntiChatFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import GRDB
import AntiChatStorage

public struct SavedArtifact: Codable, Sendable, Equatable {
    public var artifactID: String
    public var versionID: String
    public var version: Int
    public var blobID: String
    public var path: String
    public var filename: String
    public var kind: String
    public var size: Int64
}

public struct ArtifactStore: Sendable {
    public let database: AppDatabase
    public let mediaRoot: URL
    public let incognito: Bool

    public init(database: AppDatabase, mediaRoot: URL, incognito: Bool) {
        self.database = database; self.mediaRoot = mediaRoot; self.incognito = incognito
    }

    /// The store for `database`: `<container>/Media` on disk; the session's temp dir for incognito when supplied,
    /// otherwise a fresh temp dir for an in-memory store.
    public static func forDatabase(_ database: AppDatabase, mediaRoot: URL? = nil) -> ArtifactStore {
        if database.isInMemory {
            let root = mediaRoot ?? IncognitoTemp.make("out-\(UUID().uuidString)")  // owned (launch sweeps keep it)
            return ArtifactStore(database: database, mediaRoot: root, incognito: true)
        }
        return ArtifactStore(database: database, mediaRoot: AppDatabase.containerURL().appendingPathComponent("Media", isDirectory: true),
                             incognito: false)
    }

    /// Writes `data` and records it. `revises` = an artifact of the same chat → its next version; `revisesVersion` = the
    /// version that version was made from (Edit selection on an older version, M6 review #11), else the newest.
    /// `operation`: how a media version was made (R-287 AC4, stored on the version row; nil for documents).
    /// `parentVersion` (M4.T13, R-033 AC2): the version this one was made FROM when that is not the newest one (a second
    /// edit of v1 is v3 with parent v1, a sibling of v2); it must belong to the revised artifact, else the newest is used.
    public func save(chatID: String, kind: String, filename: String, data: Data, specJSON: String?, messageID: String?,
                     revises: String? = nil, revisesVersion: Int? = nil, operation: ArtifactOperation? = nil,
                     parentVersion: String? = nil,
                     now: Date = Date()) throws -> SavedArtifact {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = (filename as NSString).pathExtension.lowercased()
        let year = String(Calendar(identifier: .gregorian).component(.year, from: now))
        let dir = incognito ? mediaRoot : mediaRoot.appendingPathComponent(year, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: incognito ? [.posixPermissions: 0o700] : nil)
        } catch {
            throw FileOutError.store("\(error)")
        }
        let url = dir.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
        var wroteFile = false
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                wroteFile = true
            }
            // M4 review P1-2: a row that cannot be inserted (the chat is gone: a closed incognito session) leaves no file.
            var inserted = false
            defer { if wroteFile, !inserted { try? FileManager.default.removeItem(at: url) } }
            let saved = try database.write { db -> SavedArtifact in
                let blob: FileBlobRecord
                if let existing = try FileBlobRecord.filter(Column("sha256") == sha).fetchOne(db) {
                    // Same bytes as an earlier file: one blob (its copy is restored if it went missing).
                    if !FileManager.default.fileExists(atPath: existing.path) {
                        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: existing.path))
                    }
                    blob = existing
                } else {
                    blob = FileBlobRecord(sha256: sha, size: Int64(data.count), path: url.path, createdAt: now, origin: .generated)
                    try blob.insert(db)
                }
                let message: String? = try messageID.flatMap { id in
                    try MessageRecord.fetchOne(db, key: id) != nil ? id : nil
                }
                let artifact: ArtifactRecord
                if let revises, let existing = try ArtifactRecord.fetchOne(db, key: revises), existing.chatID == chatID {
                    artifact = existing
                } else {
                    artifact = ArtifactRecord(chatID: chatID, kind: kind, title: filename, createdAt: now)
                    try artifact.insert(db)
                }
                let previous = try ArtifactVersionRecord.filter(Column("artifact_id") == artifact.id)
                    .order(Column("n").desc).fetchOne(db)
                // The new version's parent: an explicit version id (M4.T13 edits), else the version an edit started
                // from (M6 review #11), else the newest.
                let base = try revisesVersion.flatMap { n in
                    try ArtifactVersionRecord.filter(Column("artifact_id") == artifact.id && Column("n") == n).fetchOne(db)
                } ?? previous
                let parent = try parentVersion.flatMap { id in
                    try ArtifactVersionRecord.fetchOne(db, key: id).flatMap { $0.artifactID == artifact.id ? $0.id : nil }
                } ?? base?.id
                let version = ArtifactVersionRecord(artifactID: artifact.id, n: (previous?.n ?? 0) + 1, blobID: blob.id,
                                                    specJSON: specJSON, createdByMessageID: message, createdAt: now,
                                                    parentVersionID: parent, operation: operation)
                try version.insert(db)
                return SavedArtifact(artifactID: artifact.id, versionID: version.id, version: version.n, blobID: blob.id,
                                     path: blob.path, filename: filename, kind: kind, size: Int64(data.count))
            }
            inserted = true
            return saved
        } catch let e as FileOutError {
            throw e
        } catch {
            throw FileOutError.store("\(error)")
        }
    }

    /// A picture a tool call refers to (M4.T13 `source_image_id` / `mask_id`): an artifact id (its newest version), a
    /// version id (that exact version), or an attachment id (an uploaded picture: no version, never checked, D-005).
    public struct ImageRef: Sendable, Equatable {
        public var path: String
        public var artifactID: String?
        public var versionID: String?
        public var attachmentID: String?
    }

    /// Resolves `ref` in this chat's store (nil = unknown id, or its file is gone). Artifacts of another chat are refused.
    public func resolveImage(ref: String, chatID: String? = nil) -> ImageRef? {
        let found: ImageRef? = try? database.read { db in
            if let a = try AttachmentRecord.fetchOne(db, key: ref), let b = try FileBlobRecord.fetchOne(db, key: a.blobID) {
                // An upload of another chat resolves to nothing (M6 review #19); M4 review: nor a draft's (no message).
                guard let m = a.messageID else { return nil }
                if let chatID, try MessageRecord.fetchOne(db, key: m)?.chatID != chatID { return nil }
                return ImageRef(path: b.path, attachmentID: a.id)
            }
            let version = try ArtifactVersionRecord.fetchOne(db, key: ref)
                ?? ArtifactVersionRecord.filter(Column("artifact_id") == ref).order(Column("n").desc).fetchOne(db)
            guard let v = version, let b = try FileBlobRecord.fetchOne(db, key: v.blobID) else { return nil }
            if let chatID, let owner = try ArtifactRecord.fetchOne(db, key: v.artifactID), owner.chatID != chatID { return nil }
            return ImageRef(path: b.path, artifactID: v.artifactID, versionID: v.id)
        }
        guard var r = found else { return nil }
        if !r.path.hasPrefix("/") { r.path = mediaRoot.appendingPathComponent(r.path).path }
        return FileManager.default.fileExists(atPath: r.path) ? r : nil
    }

    /// The bytes behind an image ref of chat `chatID`: an attachment of one of its messages, else one of its artifacts
    /// (the newest version). An id from another chat resolves to nothing (M6 review #19).
    public func imageData(ref: String, chatID: String) -> Data? {
        guard let path = imagePath(ref: ref, chatID: chatID) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// M5.T10: the file behind an image ref of chat `chatID` (the I2V source; same rules as `imageData`).
    public func imagePath(ref: String, chatID: String) -> String? {
        let path: String? = try? database.read { db in
            if let a = try AttachmentRecord.fetchOne(db, key: ref), let m = a.messageID,
               try MessageRecord.fetchOne(db, key: m)?.chatID == chatID {
                return try FileBlobRecord.fetchOne(db, key: a.blobID)?.path
            }
            if try ArtifactRecord.fetchOne(db, key: ref)?.chatID == chatID,
               let v = try ArtifactVersionRecord.filter(Column("artifact_id") == ref).order(Column("n").desc).fetchOne(db) {
                return try FileBlobRecord.fetchOne(db, key: v.blobID)?.path
            }
            return nil
        }
        guard let path else { return nil }
        return path.hasPrefix("/") ? path : mediaRoot.appendingPathComponent(path).path
    }

    /// AT-273 / AT-275: the pictures attached to messages of chat `chatID`, oldest first (what a file-out call's image
    /// refs can name; drafts — attachments not sent yet — are not the chat's).
    public func attachedImages(chatID: String, limit: Int = 20) -> [AttachedImage] {
        let rows = (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.display_name, t.uti FROM attachment t JOIN message m ON m.id = t.message_id
                WHERE m.chat_id = ? ORDER BY t.created_at, t.id LIMIT 200
                """, arguments: [chatID])
        }) ?? []
        let images = rows.filter { (UTType($0["uti"] as String? ?? "")?.conforms(to: .image)) == true }
            .map { AttachedImage(id: $0["id"], name: $0["display_name"] as String? ?? "") }
        return Array(images.prefix(limit))
    }

    /// M5.T10 ("animate the last image"): the newest picture of chat `chatID` — an image artifact or an image
    /// attachment of one of its messages, whichever is newer (nil = none).
    public func lastImageRef(chatID: String) -> String? {
        try? database.read { db -> String? in
            let art = try Row.fetchOne(db, sql: """
                SELECT id, created_at FROM artifact WHERE chat_id = ? AND kind = 'image' ORDER BY created_at DESC LIMIT 1
                """, arguments: [chatID])
            let atts = try Row.fetchAll(db, sql: """
                SELECT t.id, t.uti, t.created_at FROM attachment t JOIN message m ON m.id = t.message_id
                WHERE m.chat_id = ? ORDER BY t.created_at DESC LIMIT 50
                """, arguments: [chatID])
            let att = atts.first { (UTType($0["uti"] as String)?.conforms(to: .image)) == true }
            switch (art, att) {
            case let (a?, b?): return (a["created_at"] as Date? ?? .distantPast) >= (b["created_at"] as Date? ?? .distantPast) ? a["id"] : b["id"]
            case let (a?, nil): return a["id"]
            case let (nil, b?): return b["id"]
            default: return nil
            }
        } ?? nil
    }
}
