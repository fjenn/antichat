// M7.T06/T08: `mcp_server` and `mcp_tool` rows (migration `v22_mcp_tools`, Migrations+MCP.swift).
import Foundation
import GRDB

public struct MCPServerRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mcp_server"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public enum Kind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case remote, stdio, composio }
    public enum AuthKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case none, token, oauth }
    /// The ConnectionRow states (M7.T06 step 4); "tools changed" is derived (`toolsChanged`).
    public enum State: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case notConnected, connecting, connected, needsReauth, error
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var urlOrCmd: String
    public var authKind: AuthKind
    /// Keychain item name (`app.antichat.mcp.<id>` / `app.antichat.mcp.oauth`); nil for `none`.
    public var authRef: String?
    public var enabled: Bool
    public var curatedID: String?
    public var protocolVersion: String?
    public var state: State
    public var errorCode: String?
    public var toolsHash: String?
    public var lastReviewedHash: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, name, enabled, state
        case urlOrCmd = "url_or_cmd", authKind = "auth_kind", authRef = "auth_ref", curatedID = "curated_id"
        case protocolVersion = "protocol_version", errorCode = "error_code", toolsHash = "tools_hash"
        case lastReviewedHash = "last_reviewed_hash", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(id: String, kind: Kind = .remote, name: String, urlOrCmd: String, authKind: AuthKind = .none,
                authRef: String? = nil, enabled: Bool = true, curatedID: String? = nil, protocolVersion: String? = nil,
                state: State = .notConnected, errorCode: String? = nil, toolsHash: String? = nil,
                lastReviewedHash: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.name = name; self.urlOrCmd = urlOrCmd; self.authKind = authKind
        self.authRef = authRef; self.enabled = enabled; self.curatedID = curatedID; self.protocolVersion = protocolVersion
        self.state = state; self.errorCode = errorCode; self.toolsHash = toolsHash; self.lastReviewedHash = lastReviewedHash
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// M7.T08: the server's tools differ from what the user last accepted (banner + "tools changed" row).
    public var toolsChanged: Bool { toolsHash != nil && lastReviewedHash != nil && toolsHash != lastReviewedHash }
}

public struct MCPToolRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mcp_tool"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var serverID: String
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public var annotationsJSON: String
    public var descHash: String
    public var embedding: Data?
    public var enabled: Bool
    /// false = the server stopped listing it (kept for the change review until accepted).
    public var present: Bool
    /// The accepted snapshot (M7.T08): nil for a tool that was never accepted (new).
    public var reviewedHash: String?
    public var reviewedDescription: String?
    public var reviewedSchemaJSON: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case name, description, embedding, enabled, present
        case serverID = "server_id", inputSchemaJSON = "input_schema_json", annotationsJSON = "annotations_json"
        case descHash = "desc_hash", reviewedHash = "reviewed_hash", reviewedDescription = "reviewed_description"
        case reviewedSchemaJSON = "reviewed_schema_json", updatedAt = "updated_at"
    }

    public init(serverID: String, name: String, description: String = "", inputSchemaJSON: String = "{}",
                annotationsJSON: String = "{}", descHash: String, embedding: Data? = nil, enabled: Bool = true,
                present: Bool = true, reviewedHash: String? = nil, reviewedDescription: String? = nil,
                reviewedSchemaJSON: String? = nil, updatedAt: Date = Date()) {
        self.serverID = serverID; self.name = name; self.description = description; self.inputSchemaJSON = inputSchemaJSON
        self.annotationsJSON = annotationsJSON; self.descHash = descHash; self.embedding = embedding; self.enabled = enabled
        self.present = present; self.reviewedHash = reviewedHash; self.reviewedDescription = reviewedDescription
        self.reviewedSchemaJSON = reviewedSchemaJSON; self.updatedAt = updatedAt
    }

    /// The permission row key (`tool_permission.tool_key`).
    public var permissionKey: String { MCPToolRecord.permissionKey(server: serverID, tool: name) }
    public static func permissionKey(server: String, tool: String) -> String { "mcp:\(server):\(tool)" }
}

/// Reads and writes the connection rows (the Connections page, MCPHost, ToolHashReview).
public struct MCPRepository: Sendable {
    public let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func servers() throws -> [MCPServerRecord] {
        try database.read { try MCPServerRecord.order(Column("created_at")).fetchAll($0) }
    }

    public func server(_ id: String) throws -> MCPServerRecord? {
        try database.read { try MCPServerRecord.fetchOne($0, key: id) }
    }

    public func save(_ server: MCPServerRecord) throws {
        try database.write { try server.save($0) }
    }

    public func update(_ id: String, _ change: @Sendable (inout MCPServerRecord) -> Void) throws {
        try database.write { db in
            guard var s = try MCPServerRecord.fetchOne(db, key: id) else { return }
            change(&s)
            s.updatedAt = Date()
            try s.update(db)
        }
    }

    /// Deletes the server, its tools (cascade) and its permission rows.
    public func delete(_ id: String) throws {
        try database.write { db in
            _ = try MCPServerRecord.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM tool_permission WHERE tool_key LIKE ?", arguments: ["mcp:\(id):%"])
        }
    }

    /// The server's tools, present ones first by name (absent ones only when `includeRemoved`).
    public func tools(server id: String, includeRemoved: Bool = false) throws -> [MCPToolRecord] {
        try database.read { db in
            var q = MCPToolRecord.filter(Column("server_id") == id)
            if !includeRemoved { q = q.filter(Column("present") == true) }
            return try q.order(Column("name")).fetchAll(db)
        }
    }

    public func setToolEnabled(server: String, tool: String, enabled: Bool) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE mcp_tool SET enabled = ? WHERE server_id = ? AND name = ?", arguments: [enabled, server, tool])
        }
    }
}
