// M3.T03 step 7 (R-050 AC4; settings-map §5 "Recent recordings"): the newest 20 dictations with their audio.
// `add` files the helper's `.m4a` under `<mediaRoot>/<yyyy>/<sha256>.m4a` through `file_blob` (origin `recording`;
// the same bytes reuse one blob), inserts the `recording` row and then deletes every row beyond the newest 20 with
// its file (a blob still referenced by an attachment, an artifact or another recording keeps its file). Incognito:
// an in-memory database (the incognito store) never gets a row and no file is written — the audio is dropped
// (M3 contract 3; the app also passes no `recordingURL` to the helper, so nothing reaches the disk at all).
import CryptoKit
import Foundation
import GRDB

public struct RecordingRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recording"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var chatID: String?
    public var createdAt: Date
    public var durationMs: Int
    public var transcript: String
    public var fileBlobID: String
    public var language: String
    /// `parakeet` / `whisperkit` / `speechAnalyzer` (STTEngineID raw values).
    public var engine: String

    enum CodingKeys: String, CodingKey {
        case id, transcript, language, engine
        case chatID = "chat_id", createdAt = "created_at", durationMs = "duration_ms", fileBlobID = "file_blob_id"
    }

    public init(id: String = StorageID.make(), chatID: String?, createdAt: Date, durationMs: Int, transcript: String,
                fileBlobID: String, language: String, engine: String) {
        self.id = id; self.chatID = chatID; self.createdAt = createdAt; self.durationMs = durationMs
        self.transcript = transcript; self.fileBlobID = fileBlobID; self.language = language; self.engine = engine
    }
}

public struct RecordingStore: Sendable {
    public static let keep = 20
    public let database: AppDatabase
    public let mediaRoot: URL

    public init(database: AppDatabase, mediaRoot: URL) {
        self.database = database
        self.mediaRoot = mediaRoot
    }

    /// The app's store: `<container>/Media`.
    public static func standard(_ database: AppDatabase) -> RecordingStore {
        RecordingStore(database: database, mediaRoot: AppDatabase.containerURL().appendingPathComponent("Media", isDirectory: true))
    }

    /// Files `audio` (moved, not copied) and records it; nil (and the audio deleted) for an incognito store.
    @discardableResult
    public func add(audio: URL, transcript: String, language: String, engine: String, durationMs: Int, chatID: String?,
                    now: Date = Date()) throws -> RecordingRecord? {
        guard !database.isInMemory else {
            try? FileManager.default.removeItem(at: audio)
            return nil
        }
        let data = try Data(contentsOf: audio, options: .mappedIfSafe)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let year = String(Calendar(identifier: .gregorian).component(.year, from: now))
        let dir = mediaRoot.appendingPathComponent(year, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(sha).m4a")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: audio)
        } else {
            try FileManager.default.moveItem(at: audio, to: dest)
        }
        let (record, doomed) = try database.write { db -> (RecordingRecord, [String]) in
            let blob: FileBlobRecord
            if let existing = try FileBlobRecord.filter(Column("sha256") == sha).fetchOne(db) {
                blob = existing
            } else {
                blob = FileBlobRecord(sha256: sha, size: Int64(data.count), path: dest.path, createdAt: now, origin: .recording)
                try blob.insert(db)
            }
            let r = RecordingRecord(chatID: chatID, createdAt: now, durationMs: durationMs, transcript: transcript,
                                    fileBlobID: blob.id, language: language, engine: engine)
            try r.insert(db)
            return (r, try Self.prune(db))
        }
        for path in doomed { try? FileManager.default.removeItem(atPath: path) }
        return record
    }

    /// Newest first.
    public func all() throws -> [RecordingRecord] {
        try database.read { db in
            try RecordingRecord.order(Column("created_at").desc, Column("id").desc).fetchAll(db)
        }
    }

    /// The audio file of `recording`.
    public func fileURL(_ recording: RecordingRecord) throws -> URL? {
        try database.read { db in try FileBlobRecord.fetchOne(db, key: recording.fileBlobID) }.map { URL(fileURLWithPath: $0.path) }
    }

    /// Deletes one recording and its file (unless the blob is still used elsewhere).
    public func delete(id: String) throws {
        let doomed = try database.write { db -> [String] in
            guard let r = try RecordingRecord.fetchOne(db, key: id) else { return [] }
            try r.delete(db)
            return try Self.dropBlobIfUnused(db, r.fileBlobID)
        }
        for path in doomed { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Rows beyond the newest `keep`; returns the file paths to delete after the transaction.
    static func prune(_ db: Database) throws -> [String] {
        let old = try RecordingRecord.order(Column("created_at").desc, Column("id").desc).limit(-1, offset: keep).fetchAll(db)
        var paths: [String] = []
        for r in old {
            try r.delete(db)
            paths += try dropBlobIfUnused(db, r.fileBlobID)
        }
        return paths
    }

    static func dropBlobIfUnused(_ db: Database, _ blobID: String) throws -> [String] {
        guard try !LibraryIndex.isReferenced(blobID, db), let blob = try FileBlobRecord.fetchOne(db, key: blobID) else { return [] }
        try blob.delete(db)
        return [blob.path]
    }
}
