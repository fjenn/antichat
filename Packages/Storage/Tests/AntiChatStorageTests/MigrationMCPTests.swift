// M7.T06 definition of done: `v22_mcp_tools` adds `mcp_server` + `mcp_tool` (architecture §5.1), the down step
// restores the previous schema exactly, and the repository round-trips (cascade, permission rows). The pre-migration
// backup is MigrationRunnerTests (a): every fixture, v20_projects included, is backed up as `pre-<head>-…` first.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct MigrationMCPTests {
    @Test func upThenDownRestoresThePreviousSchema() throws {
        let q = try DatabaseQueue()
        var m = Migrations.migrator()
        m.eraseDatabaseOnSchemaChange = false
        let previous = Migrations.identifiers[Migrations.identifiers.firstIndex(of: "v22_mcp_tools")! - 1]
        try m.migrate(q, upTo: previous)
        let before = try q.read(schemaDump)
        try m.migrate(q, upTo: "v22_mcp_tools")
        let cols = try q.read { db in try db.columns(in: "mcp_server").map(\.name) + db.columns(in: "mcp_tool").map(\.name) }
        for c in ["kind", "url_or_cmd", "auth_ref", "enabled", "tools_hash", "last_reviewed_hash", "protocol_version",
                  "input_schema_json", "annotations_json", "desc_hash", "embedding", "reviewed_hash"] {
            #expect(cols.contains(c), "missing \(c)")
        }
        try q.write { try Migrations.v22McpToolsDown($0) }
        #expect(try q.read(schemaDump) == before)
        #expect(try q.read { try m.appliedIdentifiers($0) }.contains("v22_mcp_tools") == false)
    }

    @Test func repositoryRoundTripAndCascade() throws {
        let db = try AppDatabase.inMemory()
        let repo = MCPRepository(db)
        #expect(try repo.servers().isEmpty, "no rows until the user adds a connection")
        try repo.save(MCPServerRecord(id: "s1", name: "Docs", urlOrCmd: "https://docs.example/mcp", authKind: .token, authRef: "app.antichat.mcp.s1"))
        try db.write { d in
            try MCPToolRecord(serverID: "s1", name: "search", descHash: "h").save(d)
            try MCPToolRecord(serverID: "s1", name: "gone", descHash: "g", present: false).save(d)
            try ToolPermissionRecord(toolKey: MCPToolRecord.permissionKey(server: "s1", tool: "search"), policy: .block).save(d)
            try ToolPermissionRecord(toolKey: "write_note", policy: .always).save(d)
        }
        #expect(try repo.tools(server: "s1").map(\.name) == ["search"])
        #expect(try repo.tools(server: "s1", includeRemoved: true).count == 2)
        try repo.update("s1") { $0.state = .connected; $0.toolsHash = "a"; $0.lastReviewedHash = "b" }
        #expect(try repo.server("s1")?.toolsChanged == true)
        try repo.delete("s1")
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM mcp_tool") } == 0)
        #expect(try db.read { try String.fetchAll($0, sql: "SELECT tool_key FROM tool_permission") } == ["write_note"])
    }
}
