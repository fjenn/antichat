// M7.T06 (R-081, R-258; G-030) + M7.T08 (R-260): remote MCP connections. architecture §5.1 `mcp_server`, extended:
//   mcp_server  one connection the user added (none exist until they do, R-081 AC1): kind remote|stdio|composio,
//               url_or_cmd, auth_kind none|token|oauth, auth_ref (the Keychain item name; secrets never in the DB),
//               enabled, the negotiated protocol_version, state + error code for the Connections row, curated_id when
//               added from the curated list (its readOnlyHint is then trusted, R-081 AC2), tools_hash (the current
//               `tools/list`), last_reviewed_hash (what the user accepted; M7.T08 banner when they differ).
//   mcp_tool    the server's tools from the last `tools/list`: description, input schema, annotations, desc_hash
//               (M7.T08 ToolHashReview), the name+description embedding for load-when-needed (M7.T14), the per-tool
//               switch, and the reviewed snapshot (`reviewed_*`, what the user last accepted) for the change diff.
//               A tool the server stopped listing keeps its row with `present = 0` until the change is accepted.
// Per-tool permissions are `tool_permission` rows keyed `mcp:<server_id>:<tool>` (no new table).
// Numbered v22 on purpose (v21 is M3's voice migration on another branch); renumber at merge if needed.
import GRDB

extension Migrations {
    static func v22McpTools(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE mcp_server (
              id TEXT PRIMARY KEY NOT NULL,
              kind TEXT NOT NULL DEFAULT 'remote' CHECK (kind IN ('remote', 'stdio', 'composio')),
              name TEXT NOT NULL,
              url_or_cmd TEXT NOT NULL,
              auth_kind TEXT NOT NULL DEFAULT 'none' CHECK (auth_kind IN ('none', 'token', 'oauth')),
              auth_ref TEXT,
              enabled BOOLEAN NOT NULL DEFAULT 1,
              curated_id TEXT,
              protocol_version TEXT,
              state TEXT NOT NULL DEFAULT 'notConnected'
                CHECK (state IN ('notConnected', 'connecting', 'connected', 'needsReauth', 'error')),
              error_code TEXT,
              tools_hash TEXT,
              last_reviewed_hash TEXT,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL
            );
            CREATE TABLE mcp_tool (
              server_id TEXT NOT NULL REFERENCES mcp_server(id) ON DELETE CASCADE,
              name TEXT NOT NULL,
              description TEXT NOT NULL DEFAULT '',
              input_schema_json TEXT NOT NULL DEFAULT '{}',
              annotations_json TEXT NOT NULL DEFAULT '{}',
              desc_hash TEXT NOT NULL,
              embedding BLOB,
              enabled BOOLEAN NOT NULL DEFAULT 1,
              present BOOLEAN NOT NULL DEFAULT 1,
              reviewed_hash TEXT,
              reviewed_description TEXT,
              reviewed_schema_json TEXT,
              updated_at DOUBLE NOT NULL,
              PRIMARY KEY (server_id, name)
            );
            """)
    }

    /// The down step (M7.T06 rollback): drops both tables and the server's permission rows. Restoring
    /// `Backups/pre-v22_mcp_tools-<ts>.sqlite` (MigrationRunner) is the other way back.
    public static func v22McpToolsDown(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM tool_permission WHERE tool_key LIKE 'mcp:%';
            DROP TABLE mcp_tool;
            DROP TABLE mcp_server;
            DELETE FROM grdb_migrations WHERE identifier = 'v22_mcp_tools';
            """)
    }
}
