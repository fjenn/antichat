// GRDB record for `chat` (architecture §5.1).
import Foundation
import GRDB

public struct ChatRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: String
    public var title: String
    public var titleState: TitleState
    /// Immutable once the chat has a message (R-210; enforced by the `chat_mode_locked` trigger).
    public var mode: ChatMode
    public var projectID: String?
    public var pinned: Bool
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Last node of the active path (R-296 "current leaf").
    public var leafMessageID: String?
    public var memoryEnabled: Bool
    /// Per-chat tool toggles, JSON object (M1.T16/T17 own the shape).
    public var toolsJSON: String?
    public var modelSlotSnapshot: String?
    public var source: ChatSource
    public var sourceID: String?
    public var importNotice: ImportNotice?
    /// M1.T19 (`v4_unread`): a reply finished while the chat was not on screen; cleared when it is opened.
    public var unread: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, mode, pinned, source
        case titleState = "title_state", projectID = "project_id", archivedAt = "archived_at"
        case createdAt = "created_at", updatedAt = "updated_at", leafMessageID = "leaf_message_id"
        case memoryEnabled = "memory_enabled", toolsJSON = "tools_json", modelSlotSnapshot = "model_slot_snapshot"
        case sourceID = "source_id", importNotice = "import_notice", unread
    }

    public init(
        id: String = StorageID.make(), title: String = "", titleState: TitleState = .pending, mode: ChatMode = .normal,
        projectID: String? = nil, pinned: Bool = false, archivedAt: Date? = nil, createdAt: Date = Date(),
        updatedAt: Date? = nil, leafMessageID: String? = nil, memoryEnabled: Bool = true, toolsJSON: String? = nil,
        modelSlotSnapshot: String? = nil, source: ChatSource = .local, sourceID: String? = nil,
        importNotice: ImportNotice? = nil, unread: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleState = titleState
        self.mode = mode
        self.projectID = projectID
        self.pinned = pinned
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.leafMessageID = leafMessageID
        self.memoryEnabled = memoryEnabled
        self.toolsJSON = toolsJSON
        self.modelSlotSnapshot = modelSlotSnapshot
        self.source = source
        self.sourceID = sourceID
        self.importNotice = importNotice
        self.unread = unread
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let pinned = Column(CodingKeys.pinned)
        public static let archivedAt = Column(CodingKeys.archivedAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let leafMessageID = Column(CodingKeys.leafMessageID)
    }
}
