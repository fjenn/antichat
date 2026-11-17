// M8.T02 step 1 (R-242, R-243, R-060 AC5; G-035): topic memory. architecture §5.1 `memory_item`, extended:
//   memory_topic  one row per (scope, project, name NOCASE); `sensitive_category` = one of the five R-060 AC3
//                 categories when the model tagged it (a privacy setting, not a filter: VISION §2.4, D-006).
//   memory_item   one fact: topic + scope (+ project), key ≤ 64, text ≤ 500, state active|pending|deleted, origin.
//   memory_event  the undo log: one row per add/update/delete with the before/after JSON.
//   chat          `memory_snapshot_json` + `memory_snapshot_hash`: the frozen block of the chat's first send (R-243).
// `project_id` has no foreign key yet: `project` arrives with M8.T04, whose migration adds the FK by table rebuild.
// Active items are mirrored into `chunk(source='memory', source_id=item id)` (+ vec, fts) by MemoryStore.
import GRDB

extension Migrations {
    static func v18Memory(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE memory_topic (
              id TEXT PRIMARY KEY NOT NULL,
              scope TEXT NOT NULL CHECK (scope IN ('global', 'project')),
              project_id TEXT,
              name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
              sensitive_category TEXT CHECK (sensitive_category IN ('health', 'sexuality', 'religion', 'politics', 'finances')),
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL,
              CHECK ((scope = 'project') = (project_id IS NOT NULL))
            );
            CREATE UNIQUE INDEX memory_topic_name ON memory_topic(scope, ifnull(project_id, ''), name COLLATE NOCASE);
            CREATE TABLE memory_item (
              id TEXT PRIMARY KEY NOT NULL,
              topic_id TEXT NOT NULL REFERENCES memory_topic(id) ON DELETE CASCADE,
              scope TEXT NOT NULL CHECK (scope IN ('global', 'project')),
              project_id TEXT,
              key TEXT NOT NULL CHECK (length(key) BETWEEN 1 AND 64),
              text TEXT NOT NULL CHECK (length(text) BETWEEN 1 AND 500),
              state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'pending', 'deleted')),
              origin TEXT NOT NULL CHECK (origin IN ('user', 'tool', 'review', 'import')),
              source_message_id TEXT,
              source_chat_id TEXT,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL,
              deleted_at DOUBLE,
              CHECK ((scope = 'project') = (project_id IS NOT NULL))
            );
            CREATE INDEX memory_item_scope ON memory_item(scope, project_id, state);
            CREATE INDEX memory_item_topic ON memory_item(topic_id);
            CREATE TABLE memory_event (
              id TEXT PRIMARY KEY NOT NULL,
              item_id TEXT NOT NULL REFERENCES memory_item(id) ON DELETE CASCADE,
              op TEXT NOT NULL CHECK (op IN ('add', 'update', 'delete')),
              before_json TEXT,
              after_json TEXT,
              message_id TEXT,
              created_at DOUBLE NOT NULL,
              undone_at DOUBLE
            );
            CREATE INDEX memory_event_item ON memory_event(item_id, created_at);
            ALTER TABLE chat ADD COLUMN memory_snapshot_json TEXT;
            ALTER TABLE chat ADD COLUMN memory_snapshot_hash TEXT;
            """)
    }

    /// M8.T03 step 6 (R-246 AC1): the background review's rows. `pending` = it was unsure, the user chooses Save or
    /// Dismiss; `saved` = stored (by the review when certain, owner 2026-11-16, or by the user's Save tap; either way
    /// MemoryStore.insert, origin review); `dismissed` = the user said no.
    static func v19MemorySuggestion(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE memory_suggestion (
              id TEXT PRIMARY KEY NOT NULL,
              text TEXT NOT NULL CHECK (length(text) BETWEEN 1 AND 500),
              topic TEXT NOT NULL,
              scope TEXT NOT NULL DEFAULT 'global' CHECK (scope IN ('global', 'project')),
              project_id TEXT,
              sensitive_category TEXT,
              source_chat_ids_json TEXT NOT NULL DEFAULT '[]',
              state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'saved', 'dismissed')),
              created_at DOUBLE NOT NULL,
              decided_at DOUBLE
            );
            CREATE INDEX memory_suggestion_state ON memory_suggestion(state, created_at);
            """)
    }
}
