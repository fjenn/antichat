// Stores a composer paste card (M1.T08 step 6) as an `attachment` + `file_blob` row (`origin=upload`,
// architecture §5.1). On disk the bytes go to `<container>/Media/<yyyy>/<sha256>.txt` (architecture §5 file
// layout); for an in-memory (Incognito) database they stay in process memory and never touch disk (R-090).
// Identical pastes share one blob (`file_blob.sha256` is unique). The send path (M1.T06) calls `save` with the
// message id; drafts (M1.T21) call it with `messageID: nil`.
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public final class PastedTextAttachmentStore: Sendable {
    public let database: AppDatabase
    /// `<container>/Media`; ignored for an in-memory database.
    public let mediaRoot: URL
    private let memory = InMemoryBlobs()

    public static let uti = "public.plain-text"

    /// M6.T01: paste cards only — a file attachment of a `.txt` has the same UTI but went through intake
    /// (`extract_state` ≠ none); its text enters the prompt as an untrusted document (M6.T02), never as a paste.
    public static var isPasteCard: SQLExpression {
        Column("uti") == uti && Column("extract_state") == ExtractState.none.rawValue
    }

    public init(database: AppDatabase, mediaRoot: URL) {
        self.database = database
        self.mediaRoot = mediaRoot
    }

    /// `<container>/Media` for the app database.
    public static func defaultMediaRoot() -> URL {
        AppDatabase.containerURL().appendingPathComponent("Media", isDirectory: true)
    }

    /// Writes `text` (UTF-8) and inserts its rows.
    /// - Parameter displayName: the localized card title (`composer.pasteCard.title`), shown on the sent message.
    @discardableResult
    public func save(text: String, displayName: String, messageID: String?, now: Date = Date()) throws -> AttachmentRecord {
        let data = Data(text.utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path: String
        if database.isInMemory {
            path = "memory:\(sha)"
            memory.put(sha, data)
        } else {
            let year = Calendar(identifier: .gregorian).component(.year, from: now)
            let dir = mediaRoot.appendingPathComponent(String(year), isDirectory: true)
            let file = dir.appendingPathComponent("\(sha).txt")
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
            path = file.path
        }
        return try AttachmentRepository(database).insert(
            sha256: sha, size: Int64(data.count), path: path, origin: .upload, messageID: messageID,
            displayName: displayName, uti: Self.uti, now: now)
    }

    /// The text of an attachment saved by this store.
    public func text(of attachment: AttachmentRecord) throws -> String? {
        guard let blob = try AttachmentRepository(database).blob(id: attachment.blobID) else { return nil }
        return text(of: blob)
    }

    /// The text of a blob saved by this store, without touching the database (the turn's prompt assembly calls
    /// it inside its write transaction).
    public func text(of blob: FileBlobRecord) -> String? {
        if blob.path.hasPrefix("memory:") {
            return memory.get(blob.sha256).map { String(decoding: $0, as: UTF8.self) }
        }
        return try? String(contentsOf: URL(fileURLWithPath: blob.path), encoding: .utf8)
    }
}

/// Incognito blob bytes: process memory only, gone when the store is released.
private final class InMemoryBlobs: @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func put(_ sha: String, _ data: Data) { lock.withLock { blobs[sha] = data } }
    func get(_ sha: String) -> Data? { lock.withLock { blobs[sha] } }
}
