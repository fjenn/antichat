// M8.T04 step 1 (R-064; G-035): projects. architecture §5.1 `chat.project_id` (present since v1) gets its tables:
//   project              name ≤ 60, SF Symbol icon (24-symbol picker), memory_mode global|project, linked folder.
//   project_instruction  one text per project (≤ 8,000 chars), stable prompt layer of the project's chats.
//   project_file         copied (file_blob, refcounted) or linked (rel_path under the linked folder) documents with
//                        their index state; chunks are `chunk(source='project_file', source_id=project_file.id)`.
//   chat                 index (project_id, updated_at); `project_instruction_text/hash` = the instructions frozen at
//                        the chat's first send (R-243 frozen-prefix rule; A-M8-T04a: the text, not only its hash).
// memory_topic gets the project foreign key M8.T02 deferred (table rebuild; GRDB runs migrations with foreign keys
// off and checks them after), ON DELETE CASCADE so a deleted project takes its project-only memory with it. Project-
// scope memory rows cannot exist before this migration (no project to point at); any stray ones are dropped so the
// foreign-key check passes.
import GRDB

extension Migrations {
    static func v20Projects(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE project (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
              icon TEXT NOT NULL DEFAULT 'folder',
              memory_mode TEXT NOT NULL DEFAULT 'global' CHECK (memory_mode IN ('global', 'project')),
              linked_folder_bookmark BLOB,
              linked_folder_path TEXT,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL,
              deleted_at DOUBLE
            );
            CREATE TABLE project_instruction (
              project_id TEXT PRIMARY KEY NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              text TEXT NOT NULL DEFAULT '' CHECK (length(text) <= 8000),
              updated_at DOUBLE NOT NULL
            );
            CREATE TABLE project_file (
              id TEXT PRIMARY KEY NOT NULL,
              project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              blob_id TEXT REFERENCES file_blob(id) ON DELETE SET NULL,
              display_name TEXT NOT NULL,
              uti TEXT,
              size INTEGER NOT NULL DEFAULT 0,
              rel_path TEXT,
              origin TEXT NOT NULL CHECK (origin IN ('copied', 'linked')),
              text_tokens INTEGER,
              pages INTEGER,
              index_state TEXT NOT NULL DEFAULT 'pending' CHECK (index_state IN ('pending', 'indexing', 'ready', 'error')),
              progress DOUBLE NOT NULL DEFAULT 0,
              error_code TEXT,
              mtime DOUBLE,
              created_at DOUBLE NOT NULL
            );
            CREATE INDEX project_file_project ON project_file(project_id, origin);
            CREATE UNIQUE INDEX project_file_linked ON project_file(project_id, rel_path) WHERE rel_path IS NOT NULL;
            CREATE INDEX project_file_blob ON project_file(blob_id);
            CREATE INDEX chat_project ON chat(project_id, updated_at);
            ALTER TABLE chat ADD COLUMN project_instruction_text TEXT;
            ALTER TABLE chat ADD COLUMN project_instruction_hash TEXT;
            CREATE TABLE memory_topic_new (
              id TEXT PRIMARY KEY NOT NULL,
              scope TEXT NOT NULL CHECK (scope IN ('global', 'project')),
              project_id TEXT REFERENCES project(id) ON DELETE CASCADE,
              name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
              sensitive_category TEXT CHECK (sensitive_category IN ('health', 'sexuality', 'religion', 'politics', 'finances')),
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL,
              CHECK ((scope = 'project') = (project_id IS NOT NULL))
            );
            DELETE FROM memory_event WHERE item_id IN (SELECT id FROM memory_item WHERE scope = 'project');
            DELETE FROM memory_item WHERE scope = 'project';
            DELETE FROM memory_topic WHERE scope = 'project';
            INSERT INTO memory_topic_new SELECT id, scope, project_id, name, sensitive_category, created_at, updated_at FROM memory_topic;
            DROP TABLE memory_topic;
            ALTER TABLE memory_topic_new RENAME TO memory_topic;
            CREATE UNIQUE INDEX memory_topic_name ON memory_topic(scope, ifnull(project_id, ''), name COLLATE NOCASE);
            """)
    }
}
