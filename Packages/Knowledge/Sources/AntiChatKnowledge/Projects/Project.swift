// Ported from osaurus-ai/osaurus@66c3dde:Models/Project/Project.swift (P-media-01; port, not vendor): a project =
// name + icon + instructions "prepended to the system prompt of every chat" + files / a linked folder. The JSON-file
// store becomes GRDB rows (`project`, `project_instruction`, `project_file`; migration v20_projects).
import AntiChatStorage
import Foundation
import GRDB

public enum ProjectMemoryMode: String, Codable, Sendable { case global, project }

public struct Project: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static let databaseTableName = "project"
    public var id: String
    public var name: String
    public var icon: String
    public var memoryMode: ProjectMemoryMode
    public var linkedFolderBookmark: Data?
    public var linkedFolderPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, memoryMode = "memory_mode", linkedFolderBookmark = "linked_folder_bookmark",
             linkedFolderPath = "linked_folder_path", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    /// The 24-symbol icon picker (SF Symbols).
    public static let icons = [
        "folder", "briefcase", "book", "graduationcap", "hammer", "wrench.and.screwdriver", "paintbrush", "music.note",
        "camera", "film", "gamecontroller", "heart", "leaf", "house", "airplane", "car", "cart", "dollarsign.circle",
        "chart.bar", "lightbulb", "star", "flag", "globe", "person.2",
    ]
    public static let maxName = 60
    public static let maxInstructions = 8_000
}

public enum ProjectFileOrigin: String, Codable, Sendable { case copied, linked }
public enum ProjectIndexState: String, Codable, Sendable { case pending, indexing, ready, error }

public struct ProjectFile: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static let databaseTableName = "project_file"
    public static let chunkSource = "project_file"
    public var id: String
    public var projectID: String
    public var blobID: String?
    public var displayName: String
    public var uti: String?
    public var size: Int64
    public var relPath: String?
    public var origin: ProjectFileOrigin
    public var textTokens: Int?
    public var pages: Int?
    public var indexState: ProjectIndexState
    public var progress: Double
    public var errorCode: String?
    public var mtime: Double?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, projectID = "project_id", blobID = "blob_id", displayName = "display_name", uti, size, relPath = "rel_path",
             origin, textTokens = "text_tokens", pages, indexState = "index_state", progress, errorCode = "error_code", mtime,
             createdAt = "created_at"
    }
}

/// A project as the sidebar / list shows it.
public struct ProjectSummary: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var icon: String
    public var chatCount: Int
    public var updatedAt: Date
}
