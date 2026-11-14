// GRDB records for the other v1_core tables (architecture §5.1): attachment, file_blob, draft, feedback,
// media_job, download, local_counter. Their owners (C-018 intake, P-media-10 jobs, P-platform-03 downloads)
// add behaviour later; v1 fixes the columns.
import Foundation
import GRDB

public struct FileBlobRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_blob"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var sha256: String
    public var size: Int64
    /// Path inside the media store (`…/AntiChat/Media/<yyyy>/<sha256>.<ext>`).
    public var path: String
    public var createdAt: Date
    public var origin: BlobOrigin
    enum CodingKeys: String, CodingKey { case id, sha256, size, path, origin, createdAt = "created_at" }

    public init(id: String = StorageID.make(), sha256: String, size: Int64, path: String, createdAt: Date = Date(),
                origin: BlobOrigin) {
        self.id = id; self.sha256 = sha256; self.size = size; self.path = path; self.createdAt = createdAt
        self.origin = origin
    }
}

public struct AttachmentRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    /// nil while the attachment sits in a draft.
    public var messageID: String?
    public var blobID: String
    public var displayName: String
    public var uti: String
    public var pages: Int?
    public var ocrState: OCRState
    public var excerptPolicy: ExcerptPolicy
    public var createdAt: Date
    /// v14 (M6.T01): extraction state of a file attachment (`none` for paste cards).
    public var extractState: ExtractState
    /// v14: tokens of the extracted text by the active model's tokenizer (M6.T02 fills it).
    public var tokenCount: Int?
    /// v14: `ExtractedDocument.units` as JSON (page / sheet / slide / section map).
    public var pageMapJSON: String?
    /// v14: helper caption for an image (M6.T06).
    public var captionText: String?
    /// v14: OCR text of an image or scanned pages (M6.T04).
    public var ocrText: String?
    enum CodingKeys: String, CodingKey {
        case id, uti, pages
        case messageID = "message_id", blobID = "blob_id", displayName = "display_name", ocrState = "ocr_state"
        case excerptPolicy = "excerpt_policy", createdAt = "created_at"
        case extractState = "extract_state", tokenCount = "token_count", pageMapJSON = "page_map_json"
        case captionText = "caption_text", ocrText = "ocr_text"
    }

    public init(id: String = StorageID.make(), messageID: String?, blobID: String, displayName: String, uti: String,
                pages: Int? = nil, ocrState: OCRState = .none, excerptPolicy: ExcerptPolicy = .whole,
                createdAt: Date = Date(), extractState: ExtractState = .none, tokenCount: Int? = nil,
                pageMapJSON: String? = nil, captionText: String? = nil, ocrText: String? = nil) {
        self.id = id; self.messageID = messageID; self.blobID = blobID; self.displayName = displayName
        self.uti = uti; self.pages = pages; self.ocrState = ocrState; self.excerptPolicy = excerptPolicy
        self.createdAt = createdAt; self.extractState = extractState; self.tokenCount = tokenCount
        self.pageMapJSON = pageMapJSON; self.captionText = captionText; self.ocrText = ocrText
    }
}

public struct DraftRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "draft"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    /// The key used for the draft of a chat that does not exist yet.
    public static let newChatKey = "new"
    /// A chat id, or `newChatKey`.
    public var chatID: String
    public var text: String
    /// Attachment ids / descriptors, JSON (R-302; M1.T21 owns the shape).
    public var attachmentsJSON: String?
    public var updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case text, chatID = "chat_id", attachmentsJSON = "attachments_json", updatedAt = "updated_at"
    }

    public init(chatID: String, text: String, attachmentsJSON: String? = nil, updatedAt: Date = Date()) {
        self.chatID = chatID; self.text = text; self.attachmentsJSON = attachmentsJSON; self.updatedAt = updatedAt
    }
}

public struct FeedbackRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "feedback"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var messageID: String
    public var kind: FeedbackKind
    public var note: String?
    public var createdAt: Date
    enum CodingKeys: String, CodingKey { case kind, note, messageID = "message_id", createdAt = "created_at" }

    public init(messageID: String, kind: FeedbackKind, note: String? = nil, createdAt: Date = Date()) {
        self.messageID = messageID; self.kind = kind; self.note = note; self.createdAt = createdAt
    }
}

public struct MediaJobRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "media_job"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var chatID: String
    public var messageID: String?
    public var kind: String
    public var specJSON: String
    public var state: MediaJobState
    public var progress: Double
    public var etaS: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorCode: String?
    /// M4.T04: the helper launch running it (`HelloAck.engineInstanceID`); queue position (nil once finished).
    public var engineInstanceID: String?
    public var position: Int?
    enum CodingKeys: String, CodingKey {
        case id, kind, state, progress, position
        case chatID = "chat_id", messageID = "message_id", specJSON = "spec_json", etaS = "eta_s"
        case createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at", errorCode = "error_code"
        case engineInstanceID = "engine_instance_id"
    }

    public init(id: String = StorageID.make(), chatID: String, messageID: String? = nil, kind: String,
                specJSON: String, state: MediaJobState = .queued, progress: Double = 0, etaS: Double? = nil,
                createdAt: Date = Date(), startedAt: Date? = nil, finishedAt: Date? = nil, errorCode: String? = nil,
                engineInstanceID: String? = nil, position: Int? = nil) {
        self.id = id; self.chatID = chatID; self.messageID = messageID; self.kind = kind; self.specJSON = specJSON
        self.state = state; self.progress = progress; self.etaS = etaS; self.createdAt = createdAt
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.errorCode = errorCode
        self.engineInstanceID = engineInstanceID; self.position = position
    }
}

public struct DownloadRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "download"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var fileSHA256: String
    public var url: String
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    public var state: String
    public var retries: Int
    /// The downloader's finished-chunk map (JSON), P-platform-03.
    public var chunkMap: String?
    public var createdAt: Date
    public var updatedAt: Date
    // v9_download (M2.T08): queue columns.
    public var pack: String?
    public var priority: Int
    public var modelID: String?
    /// Every source URL in order (JSON array).
    public var sources: String?
    /// Catalog `chunk{size, sha256[]}` (JSON).
    public var chunkSHA: String?
    /// `user` / `system` while paused.
    public var pauseReason: String?
    /// Copy key of the last error.
    public var error: String?
    enum CodingKeys: String, CodingKey {
        case id, url, state, retries, pack, priority, sources, error
        case fileSHA256 = "file_sha256", bytesDone = "bytes_done", bytesTotal = "bytes_total"
        case chunkMap = "chunk_map", createdAt = "created_at", updatedAt = "updated_at"
        case modelID = "model_id", chunkSHA = "chunk_sha", pauseReason = "pause_reason"
    }

    public init(id: String = StorageID.make(), fileSHA256: String, url: String, bytesDone: Int64 = 0,
                bytesTotal: Int64? = nil, state: String = "queued", retries: Int = 0, chunkMap: String? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, pack: String? = nil, priority: Int = 0,
                modelID: String? = nil, sources: String? = nil, chunkSHA: String? = nil, pauseReason: String? = nil,
                error: String? = nil) {
        self.id = id; self.fileSHA256 = fileSHA256; self.url = url; self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal; self.state = state; self.retries = retries; self.chunkMap = chunkMap
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.pack = pack; self.priority = priority; self.modelID = modelID; self.sources = sources
        self.chunkSHA = chunkSHA; self.pauseReason = pauseReason; self.error = error
    }
}

public struct LocalCounterRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "local_counter"
    public var key: String
    public var value: Int64

    public init(key: String, value: Int64) { self.key = key; self.value = value }

    /// Adds `delta` to the counter `key` (creating it at 0) and returns the new value. Local only, never sent.
    @discardableResult
    public static func increment(_ key: String, by delta: Int64 = 1, in db: Database) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO local_counter (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = value + excluded.value
            """, arguments: [key, delta])
        return try Int64.fetchOne(db, sql: "SELECT value FROM local_counter WHERE key = ?", arguments: [key]) ?? 0
    }
}
