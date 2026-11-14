// M8.T06 step 7 (R-092 AC2; G-058): `import_record` — one row per imported conversation, keyed by its source and
// external id, so a re-import skips an unchanged conversation and replaces a newer one in place (same chat id,
// project, pins) instead of creating a duplicate. The "Imported" tag is `chat.source` (chatgpt | claude | antichat,
// present since v1; A-M8-T06a: no separate `chat.imported_from` column).
import GRDB

extension Migrations {
    static func v24ImportRecord(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE import_record (
              id TEXT PRIMARY KEY NOT NULL,
              source TEXT NOT NULL CHECK (source IN ('chatgpt', 'claude', 'antichat')),
              external_key TEXT NOT NULL,
              chat_id TEXT REFERENCES chat(id) ON DELETE CASCADE,
              external_updated_at DOUBLE,
              file_sha256 TEXT,
              imported_at DOUBLE NOT NULL,
              UNIQUE (source, external_key)
            );
            CREATE INDEX import_record_chat ON import_record(chat_id);
            """)
    }
}
