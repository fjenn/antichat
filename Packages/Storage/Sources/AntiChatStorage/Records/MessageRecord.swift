// GRDB records for `message` and `message_part` (architecture §5.1, P-shell-03). JSON columns are typed:
// GRDB stores nested Codable values as JSON text.
import Foundation
import GRDB

/// Per-message provenance (R-234): stored in `message.provenance_json`.
/// One host a turn contacted (`provenance_json.network = [{host, category}]`, M2.T03).
public struct NetworkHost: Codable, Sendable, Equatable, Hashable {
    public var host: String
    public var category: String
    public init(host: String, category: String) { self.host = host; self.category = category }
}

public struct MessageProvenance: Codable, Sendable, Equatable {
    public var modelSHA: String?
    public var mode: ChatMode?
    /// Sampling parameters used (temperature, top_p, top_k, seed, max_tokens, …).
    public var sampling: [String: Double]?
    public var tokPerS: Double?
    /// Web search sources, memory reads and the skill used (later milestones fill them).
    public var searchSources: [String]?
    public var memoryReads: [String]?
    public var skill: String?
    // M1.T25 (ProvenanceRecorder): engine-side TTFT, the prompt fingerprint and where tok/s came from.
    public var ttftMs: Double?
    /// sha256 (hex) of the canonical prompt the engine received (ProvenanceRecorder.promptHash).
    public var promptHash: String?
    /// `engine` (the turn's `usage` event) or `app-estimate` (no usage arrived: interrupted before the helper
    /// reported one; ≈ 4 characters per token over the stream's own duration).
    public var tokPerSSource: String?
    /// The turn's stable-prefix hash (`PromptManifest.prefixHash`, M1.T14 step 2), stored under the key `promptHash`
    /// (M1.md T14 step 2). Distinct from `prompt_hash` (whole prompt, M1.T25). Optional: older rows lack it.
    public var promptPrefixHash: String?
    /// M1.T15: how long the model thought (first → last reasoning token), ms; nil without reasoning. Drives
    /// "Thought for N s" when the chat is reopened.
    public var reasoningMs: Double?
    /// M1.T18: the summary node (`system_note` with `summary_of_ids`) whose text replaced the older turns in this
    /// reply's prompt. Optional: absent when the prompt carried the whole history.
    public var summaryID: String?
    /// M2.T03 (R-209 AC5): hosts the turn contacted through the gate (the globe chip); absent = no network use.
    public var network: [NetworkHost]?
    /// M6.T02 (R-270): how each attached document entered the prompt (`provenance_json.files[]`).
    public var files: [FileUse]?
    /// M7.T03 (R-250): the reply's web sources (`provenance_json.sources[]`), numbered as the model saw them; pills
    /// and the Sources panel read them after a relaunch. Absent = the reply used no web step.
    public var sources: [WebSourceRecord]?
    /// AT-250 c2 (A-M7-T03c, M7 bars): the reply's citation checks (MiniCheck + the generative verifier) are still
    /// running after the final write; its pills show the checking state until the verdict rewrites the text and
    /// clears this. Absent = settled (or no checks).
    public var citationsChecking: Bool?

    public struct WebSourceRecord: Codable, Sendable, Equatable {
        public var n: Int
        public var url: String
        public var title: String
        public var site: String
        public var date: String?
        /// The page's own icon (≤ 16 KB, from the fetched HTML's `<link rel=icon>` or `/favicon.ico`), base64.
        public var faviconData: String?
        public var snippet: String
        /// The page (or its snippet) was in the evidence the model saw; only these get pills.
        public var fetched: Bool
        enum CodingKeys: String, CodingKey { case n, url, title, site, date, faviconData = "favicon_data", snippet, fetched }
        public init(n: Int, url: String, title: String, site: String, date: String?, faviconData: String?, snippet: String, fetched: Bool) {
            self.n = n; self.url = url; self.title = title; self.site = site; self.date = date; self.faviconData = faviconData
            self.snippet = snippet; self.fetched = fetched
        }
    }

    /// M8.T05 (R-245 AC2): the project passages a retrieval-mode turn put in front of the model, numbered as the
    /// prompt numbered them (`[n]` citations resolve only to these; `provenance_json.project_sources[]`).
    public var projectSources: [ProjectSource]?

    public struct ProjectSource: Codable, Sendable, Equatable {
        public var n: Int
        public var fileID: String
        public var name: String
        /// The chunk's page ref (PDF physical page index, `Slide n`, a section label); nil = none.
        public var page: String?
        enum CodingKeys: String, CodingKey { case n, fileID = "file_id", name, page }
        public init(n: Int, fileID: String, name: String, page: String?) {
            self.n = n; self.fileID = fileID; self.name = name; self.page = page
        }
    }

    public struct FileUse: Codable, Sendable, Equatable {
        public var attachmentID: String
        /// `whole` | `excerpt`.
        public var mode: String
        /// Distinct page refs of the excerpts used, sorted (empty for whole).
        public var pages: [String]
        /// Excerpts found by keyword search only (no embedder).
        public var keywordOnly: Bool?
        /// The attachment's name (the excerpt note's `{name}`).
        public var name: String?
        /// R-270 AC2: the whole file fits the context but not the time → `[Read whole file]` with this estimate.
        public var readWholeSeconds: Int?
        /// Pages of the document (valid `(p. N)` citations of a whole file are 1…pageCount).
        public var pageCount: Int?
        /// M6.T04 (R-271 AC2): sent while the scan was still being OCR'd: the answer used pages 1…this
        /// (`files.stillReading`).
        public var stillReadingPage: Int?
        /// M6.T05/T06 (R-021, R-237): how an image was seen: `model` (a vision model), `helper` (OCR + helper
        /// caption), `unavailable` (`img.needsLargerModel`); nil for documents.
        public var vision: String?
        /// The attachment is a PDF: only a PDF's pages can be cited and opened (M6 review #12; nil = rows from before).
        public var pdf: Bool?
        enum CodingKeys: String, CodingKey {
            case attachmentID = "attachment_id", mode, pages, keywordOnly = "keyword_only", name
            case readWholeSeconds = "read_whole_s", pageCount = "page_count", stillReadingPage = "still_reading_page"
            case vision, pdf
        }
        public init(attachmentID: String, mode: String, pages: [String], keywordOnly: Bool? = nil, name: String? = nil,
                    readWholeSeconds: Int? = nil, pageCount: Int? = nil, stillReadingPage: Int? = nil, vision: String? = nil,
                    pdf: Bool? = nil) {
            self.vision = vision; self.pdf = pdf
            self.attachmentID = attachmentID; self.mode = mode; self.pages = pages; self.keywordOnly = keywordOnly
            self.name = name; self.readWholeSeconds = readWholeSeconds; self.pageCount = pageCount
            self.stillReadingPage = stillReadingPage
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, skill, promptPrefixHash = "promptHash", summaryID = "summary_id"
        case modelSHA = "model_sha", sampling = "sampling_json", tokPerS = "tok_per_s"
        case searchSources = "search_sources", memoryReads = "memory_reads"
        case ttftMs = "ttft_ms", promptHash = "prompt_hash", tokPerSSource = "tok_per_s_source"
        case reasoningMs = "reasoning_ms", network, files, sources, projectSources = "project_sources"
        case citationsChecking = "citations_checking"
    }

    public init(
        modelSHA: String? = nil, mode: ChatMode? = nil, sampling: [String: Double]? = nil, tokPerS: Double? = nil,
        searchSources: [String]? = nil, memoryReads: [String]? = nil, skill: String? = nil, ttftMs: Double? = nil,
        promptHash: String? = nil, tokPerSSource: String? = nil,
        promptPrefixHash: String? = nil, reasoningMs: Double? = nil, summaryID: String? = nil
    ) {
        self.reasoningMs = reasoningMs
        self.summaryID = summaryID
        self.ttftMs = ttftMs
        self.promptHash = promptHash
        self.tokPerSSource = tokPerSSource
        self.modelSHA = modelSHA
        self.mode = mode
        self.sampling = sampling
        self.tokPerS = tokPerS
        self.searchSources = searchSources
        self.memoryReads = memoryReads
        self.skill = skill
        self.promptPrefixHash = promptPrefixHash
    }
}

/// Token usage of one turn: stored in `message.usage_json`.
public struct MessageUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cachedTokens: Int?
    public var ttftMs: Double?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
        case cachedTokens = "cached_tokens", ttftMs = "ttft_ms"
    }

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, cachedTokens: Int? = nil, ttftMs: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.ttftMs = ttftMs
    }
}

public struct MessageRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: String
    public var chatID: String
    /// Tree edge; nil = a root (versions of the first message are sibling roots).
    public var parentID: String?
    /// The child on the active path (version selection).
    public var activeChildID: String?
    /// Order among siblings (0-based; version n of N is `position` order).
    public var position: Int
    public var role: MessageRole
    public var status: MessageStatus
    public var modelID: String?
    public var engine: String?
    public var usage: MessageUsage?
    public var provenance: MessageProvenance?
    public var contextSummary: String?
    /// Compaction node: the ids this summary replaces in the prompt (P-shell-08).
    public var summaryOfIDs: [String]?
    public var errorCode: String?
    public var createdAt: Date
    public var sourceID: String?
    public var recovered: Bool

    enum CodingKeys: String, CodingKey {
        case id, position, role, status, engine, usage = "usage_json", provenance = "provenance_json", recovered
        case chatID = "chat_id", parentID = "parent_id", activeChildID = "active_child_id", modelID = "model_id"
        case contextSummary = "context_summary", summaryOfIDs = "summary_of_ids", errorCode = "error_code"
        case createdAt = "created_at", sourceID = "source_id"
    }

    public init(
        id: String = StorageID.make(), chatID: String, parentID: String?, activeChildID: String? = nil,
        position: Int = 0, role: MessageRole, status: MessageStatus = .done, modelID: String? = nil,
        engine: String? = nil, usage: MessageUsage? = nil, provenance: MessageProvenance? = nil,
        contextSummary: String? = nil, summaryOfIDs: [String]? = nil, errorCode: String? = nil,
        createdAt: Date = Date(), sourceID: String? = nil, recovered: Bool = false
    ) {
        self.id = id
        self.chatID = chatID
        self.parentID = parentID
        self.activeChildID = activeChildID
        self.position = position
        self.role = role
        self.status = status
        self.modelID = modelID
        self.engine = engine
        self.usage = usage
        self.provenance = provenance
        self.contextSummary = contextSummary
        self.summaryOfIDs = summaryOfIDs
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.sourceID = sourceID
        self.recovered = recovered
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let chatID = Column(CodingKeys.chatID)
        public static let parentID = Column(CodingKeys.parentID)
        public static let activeChildID = Column(CodingKeys.activeChildID)
        public static let position = Column(CodingKeys.position)
        public static let status = Column(CodingKeys.status)
    }
}

public struct MessagePartRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message_part"

    public var id: Int64?
    public var messageID: String
    public var idx: Int
    public var kind: PartKind
    /// Text, or JSON for structured kinds (tool calls, citations, …).
    public var body: String
    /// Came from outside the user/model (tool output, web page): never treated as instructions.
    public var untrusted: Bool

    enum CodingKeys: String, CodingKey { case id, idx, kind, body, untrusted, messageID = "message_id" }

    public init(id: Int64? = nil, messageID: String, idx: Int, kind: PartKind, body: String, untrusted: Bool = false) {
        self.id = id
        self.messageID = messageID
        self.idx = idx
        self.kind = kind
        self.body = body
        self.untrusted = untrusted
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public enum Columns {
        public static let messageID = Column(CodingKeys.messageID)
        public static let idx = Column(CodingKeys.idx)
        public static let kind = Column(CodingKeys.kind)
    }
}

/// A part's content without its row identity (for writes, export and import).
public struct PartContent: Codable, Sendable, Equatable {
    public var kind: PartKind
    public var body: String
    public var untrusted: Bool

    public init(kind: PartKind, body: String, untrusted: Bool = false) {
        self.kind = kind
        self.body = body
        self.untrusted = untrusted
    }

    public static func text(_ body: String) -> PartContent { .init(kind: .text, body: body) }
}
