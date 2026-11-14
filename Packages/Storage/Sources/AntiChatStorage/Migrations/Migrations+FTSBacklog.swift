// AT-092 AC2 (R-092): message full-text writes can be deferred to a background pass. `message_fts_backlog` holds
// id windows of `message_part` rows that are not in `message_fts` yet: a row with `done_id < id <= to_id` (to_id NULL
// = the window is still open: every new row is deferred) skips the FTS triggers; `MessageSearchBacklog` indexes the
// windows in batches and deletes each when it is done. With no window (the normal case) the triggers behave exactly
// as v1's. Windows never overlap (a new one starts at the current max id, MessageSearchBacklog.begin).
import GRDB

extension Migrations {
    static let deferredPart = "SELECT 1 FROM message_fts_backlog b WHERE %@ > b.done_id AND (b.to_id IS NULL OR %@ <= b.to_id)"

    static func v27MessageFTSBacklog(_ db: Database) throws {
        let newDeferred = String(format: deferredPart, "new.id", "new.id")
        let oldDeferred = String(format: deferredPart, "old.id", "old.id")
        try db.execute(sql: """
            CREATE TABLE message_fts_backlog (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              from_id INTEGER NOT NULL,
              done_id INTEGER NOT NULL,
              to_id INTEGER,
              created_at DOUBLE NOT NULL
            );
            DROP TRIGGER message_part_fts_ai;
            DROP TRIGGER message_part_fts_ad;
            DROP TRIGGER message_part_fts_au;
            CREATE TRIGGER message_part_fts_ai AFTER INSERT ON message_part
              WHEN new.kind = 'text' AND NOT EXISTS (\(newDeferred))
              BEGIN INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body); END;
            CREATE TRIGGER message_part_fts_ad AFTER DELETE ON message_part
              WHEN old.kind = 'text' AND NOT EXISTS (\(oldDeferred))
              BEGIN INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body); END;
            CREATE TRIGGER message_part_fts_au AFTER UPDATE OF body, kind ON message_part
              WHEN NOT EXISTS (\(newDeferred))
              BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) SELECT 'delete', old.id, old.body WHERE old.kind = 'text';
                INSERT INTO message_fts(rowid, body) SELECT new.id, new.body WHERE new.kind = 'text';
              END;
            """)
    }
}
