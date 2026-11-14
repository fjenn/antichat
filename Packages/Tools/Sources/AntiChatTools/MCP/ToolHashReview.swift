// M7.T06 step 2 / M7.T08 step 1 (R-260; P-files-tools-12 reference: snyk/agent-scan@a69e1c354a hashes each tool's
// name, description and schema): the tool digest the change review compares.
//   desc_hash  = hex SHA-256 of  name + "\n" + description + "\n" + canonicalJSON(inputSchema)
//   canonical JSON = keys sorted at every level, no whitespace (JSONSerialization .sortedKeys; numbers and strings
//                    as JSONSerialization writes them), so a server that reorders keys does not raise a banner
//   tools_hash = hex SHA-256 of the present tools' "name:desc_hash" lines, sorted by name, joined with "\n"
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public enum ToolHash {
    public static func canonicalJSON(_ json: String) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: d, as: UTF8.self)
    }

    public static func hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func descHash(name: String, description: String, inputSchemaJSON: String) -> String {
        hex(name + "\n" + description + "\n" + canonicalJSON(inputSchemaJSON))
    }

    public static func toolsHash(_ tools: [(name: String, descHash: String)]) -> String {
        hex(tools.sorted { $0.name < $1.name }.map { "\($0.name):\($0.descHash)" }.joined(separator: "\n"))
    }
}

/// M7.T08 (R-260): what changed since the user last accepted a server's tools (the review diff).
public struct ToolChangeDiff: Sendable, Equatable {
    public struct Changed: Sendable, Equatable {
        public var name: String
        public var oldDescription: String
        public var newDescription: String
        public var oldSchemaJSON: String
        public var newSchemaJSON: String
    }
    public var changed: [Changed] = []
    public var added: [String] = []
    public var removed: [String] = []
    public init() {}
    public var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }
}

/// Stores a `tools/list` result against the accepted snapshot (M7.T06 step 2, M7.T08 steps 2–3). On every list
/// (connect, `list_changed`, the daily refresh) each tool's `desc_hash` is compared with the accepted one:
///   changed or new tool → its `tool_permission` (global) is reset to Ask (Block stays Block), so the next call shows
///                          the ApprovalCard even if it was Always allowed (rug-pull, R-260 AC1);
///   `mcp_server.tools_hash` follows the list; `last_reviewed_hash` is untouched until the user accepts (`accept`),
///   so the banner `mcp.toolsChanged` and the row state "tools changed" stay until then (also across relaunch).
public enum ToolHashReview {
    /// The diff between the accepted snapshot and the current list.
    public static func diff(server id: String, database: AppDatabase) throws -> ToolChangeDiff {
        try database.read { db in
            var d = ToolChangeDiff()
            for r in try MCPToolRecord.filter(Column("server_id") == id).order(Column("name")).fetchAll(db) {
                if !r.present { if r.reviewedHash != nil { d.removed.append(r.name) }; continue }
                guard let reviewed = r.reviewedHash else { d.added.append(r.name); continue }
                if reviewed != r.descHash {
                    d.changed.append(.init(name: r.name, oldDescription: r.reviewedDescription ?? "", newDescription: r.description,
                                           oldSchemaJSON: r.reviewedSchemaJSON ?? "{}", newSchemaJSON: r.inputSchemaJSON))
                }
            }
            return d
        }
    }

    /// [Accept] in the review: the current list becomes the accepted snapshot (`last_reviewed_hash = tools_hash`).
    public static func accept(server id: String, database: AppDatabase, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM mcp_tool WHERE server_id = ? AND present = 0", arguments: [id])
            try db.execute(sql: """
                UPDATE mcp_tool SET reviewed_hash = desc_hash, reviewed_description = description,
                  reviewed_schema_json = input_schema_json WHERE server_id = ?
                """, arguments: [id])
            try db.execute(sql: "UPDATE mcp_server SET last_reviewed_hash = tools_hash, updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, id])
        }
    }

    /// Upserts the listed tools (digest, schema, annotations), marks tools the server no longer lists as absent, and
    /// updates `mcp_server.tools_hash`. `accept` = the user consented to exactly this list (add after the consent
    /// sheet): the reviewed snapshot and `last_reviewed_hash` follow it.
    public static func apply(listed: [MCPListedTool], server id: String, database: AppDatabase, accept: Bool, now: Date) throws {
        try database.write { db in
            let existing = try MCPToolRecord.filter(Column("server_id") == id).fetchAll(db)
            let byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let names = Set(listed.map(\.name))
            for t in listed {
                // M7.T16 review #9: annotations are not in desc_hash (no banner), but a tool that turns write-type
                // (readOnlyHint dropped, destructiveHint set) loses its old trust like a changed tool.
                let becameWrite = byName[t.name].map {
                    !ToolAnnotations(json: $0.annotationsJSON).isWriteType(toolName: t.name) && t.annotations.isWriteType(toolName: t.name)
                } ?? false
                var r = byName[t.name] ?? MCPToolRecord(serverID: id, name: t.name, descHash: t.descHash, updatedAt: now)
                r.description = t.description
                r.inputSchemaJSON = t.inputSchemaJSON
                r.annotationsJSON = t.annotations.json
                r.descHash = t.descHash
                r.present = true
                r.updatedAt = now
                if accept {
                    r.reviewedHash = t.descHash; r.reviewedDescription = t.description; r.reviewedSchemaJSON = t.inputSchemaJSON
                } else if r.reviewedHash != t.descHash || becameWrite {
                    // Changed or new since the last accept: back to Ask (Block stays Block).
                    try db.execute(sql: """
                        INSERT INTO tool_permission (tool_key, scope, chat_key, policy, updated_at) VALUES (?, 'global', '', 'ask', ?)
                        ON CONFLICT (tool_key, scope, chat_key) DO UPDATE SET policy = 'ask', updated_at = excluded.updated_at
                        WHERE tool_permission.policy != 'block'
                        """, arguments: [r.permissionKey, now.timeIntervalSince1970])
                    try db.execute(sql: "DELETE FROM tool_permission WHERE tool_key = ? AND scope = 'chat' AND policy = 'always'",
                                   arguments: [r.permissionKey])
                }
                try r.save(db)
            }
            for var r in existing where !names.contains(r.name) {
                if accept { try r.delete(db); continue }
                r.present = false
                r.updatedAt = now
                try r.update(db)
            }
            let hash = ToolHash.toolsHash(listed.map { ($0.name, $0.descHash) })
            try db.execute(sql: "UPDATE mcp_server SET tools_hash = ?, updated_at = ? WHERE id = ?", arguments: [hash, now.timeIntervalSince1970, id])
            if accept {
                try db.execute(sql: "UPDATE mcp_server SET last_reviewed_hash = ? WHERE id = ?", arguments: [hash, id])
            }
        }
    }
}
