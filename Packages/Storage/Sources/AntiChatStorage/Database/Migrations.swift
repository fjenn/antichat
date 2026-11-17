// Ported from janhq/jan@7890e41:web-app/src/lib/message-branching.ts; open-webui/open-webui@f7ac7ee:backend/open_webui/models/chat_messages.py
// (P-shell-03, ported design: a message tree with parent_id, versions as siblings, the chat's current leaf;
// danny-avila/LibreChat@8d3da9b parentMessageId as the reference for parent links. No code copied.)
//
// AntiChat schema, append-only migrations (architecture §5.2: `v<N>_<what>`; future changes are `v2_…`,
// the version name is fixed by merge order, M1-plan §0 hot files). Never edit a registered migration.
//
// v1_core: table → architecture.md §5.1 row
// - `chat`            → §5.1 `chat` (+ import provenance `source`, `source_id`, `import_notice`; A-M1-T04a)
// - `message`         → §5.1 `message` (+ `summary_of_ids` for compaction nodes, P-shell-03/08; `position` =
//                       sibling order; import provenance `source_id`, `recovered`; A-M1-T04a). Provenance
//                       (R-234: model_sha, mode, sampling_json, tok_per_s) lives inside `provenance_json`.
// - `message_part`    → §5.1 `message_part`
// - `attachment`      → §5.1 `attachment`
// - `file_blob`       → §5.1 `file_blob`
// - `draft`           → §5.1 `draft` (key = chat id or `new`)
// - `feedback`        → §5.1 `feedback`
// - `media_job`       → §5.1 `media_job`
// - `download`        → §5.1 `download`
// - `local_counter`   → §5.1 `local_counter`
// - `message_fts`     → §5.1 `message_fts` (FTS5, external content = `message_text`, the kind=text view of
//                       `message_part`; hand-written triggers instead of `synchronize(withTable:)`, A-M1-T04a)
// - `chat_fts`        → §5.1 sidebar/⌘K title search (FTS5 synchronized with `chat.title` via GRDB)
// - `grdb_migrations` → §5.1 `grdb_migrations` (GRDB `DatabaseMigrator`)
// v2_think_harder (M1.T15 step 4): `chat.think_harder`, the composer's Think harder toggle per chat (new chats 0).
// v3_tool_permission (M1.T16): `tool_permission` → §5.1 `tool_permission` (tool_key, scope global/chat, policy
//                       always/ask/block; `chat_key` = chat id or '' for global, so the key has no NULLs).
// v4_unread (M1.T19 step 4; the task's `v2_unread`, numbered by merge order): `chat.unread`, set when a reply
//                       finishes in a chat that is not on screen, cleared when the chat is opened (new chats 0).
// v5_hardware_profile (M2.T01): `hardware_profile` → §5.1 `hardware_profile` (os_build, chip, gpu_cores, ram, W, B,
//                       tier, speed_class, probed_at; one row, id = 1; `profile_json` = the full HardwareProfile).
// v6_network_activity (M2.T02): `network_activity` → §5.1 `network_activity` (ts, category, host, bytes, outcome;
//                       rolling 7 days; never written for incognito, P-platform-08).
// v9_download (M2.T08): queue columns on `download` (pack, priority, model_id, sources, chunk_sha, pause_reason,
//                       error) + index on file_sha256.
// v10_consent (M2.T17): `consent` (Evil terms acceptance: kind, version, accepted_at, adult_self_declared; R-211).
//                       The chat-mode lock (R-210) is v1's `chat_mode_locked` trigger, unchanged.
// v11_chunks_vec (M2.T16): `chunk` (embedding units of finished messages: source, source_id, chat_id, ord, text) +
//                       `chunk_fts` (FTS5, external content = `chunk`) + `chunk_vec` (vec0 float[1024], rowid = chunk.id;
//                       created by ChunkTables.ensureVectorTable, outside the frozen DDL because plain SQLite has no vec0).
// v12_pending_request (M2.T24): `pending_request` (a media turn waiting for its pack: assistant_id, chat_id,
//                       user_message_id, pack, created_at; re-run once the pack is installed, R-238 AC2).
// v13_artifact (M4.T10): `artifact` + `artifact_version` (architecture §5.1; M1 never created them).
// v14_files_m6 (M6.T01): file intake columns on `attachment` (extract_state, token_count, page_map_json, caption_text,
//                       ocr_text), `retrieval` (which chunks a reply used: message_id, chunk_id, page_ref, rank; M6.T02),
//                       `chunk.page_ref` (M6.T02 DocumentIndexer), `artifact_version.parent_version_id` (M6.T09–T13).
//                       `artifact.kind` has no CHECK constraint, so the new kinds (md, csv, code, html, svg, mermaid,
//                       doc) need no table rebuild.
// v18_memory (M8.T02): `memory_topic`, `memory_item`, `memory_event` (undo log), `chat.memory_snapshot_json/hash`
//                       (body in Migrations+Memory.swift; numbered high on purpose, renumbered at merge).
// v19_memory_suggestion (M8.T03): `memory_suggestion` (background review: what it saved itself and what it asks about, R-246).
// v20_projects (M8.T04): `project`, `project_instruction`, `project_file`, chat project index + frozen instructions, memory_topic FK.
// v21_voice_recording (M3.T03; v15 on the m3/voice branch, renumbered at merge after M8's v18–v20, step 7; R-050 AC4, settings-map §5): `recording` (recent dictations: chat_id, created_at,
//                       duration_ms, transcript, file_blob_id, language, engine; the newest 20 are kept, never incognito)
//                       and `recording` in the `file_blob.origin` values (architecture §5). SQLite cannot alter a CHECK,
//                       so `file_blob` is rebuilt (create new → copy → drop → rename; GRDB defers foreign keys during a
//                       migration and checks them at its end; the references in `attachment` / `artifact_version` name
//                       `file_blob` and stay valid). The pre-migration backup is AppDatabase.backupBeforeMigrating (M1).
// v22_mcp_tools (M7.T06/T08): `mcp_server` (architecture §5.1) + `mcp_tool` (tools, hashes, reviewed snapshot); body in
//                       Migrations+MCP.swift (v21 is taken by M3 on another branch; renumbered at merge).
// v24_import_record (M8.T06): `import_record` (source, external_key) → chat, for re-import dedup.
// v26_photo_media_job (M4.T04): `media_job.engine_instance_id` (lost detection, R-291 AC2) + `position` (queue order);
//                       appended after M8's v24_import_record (append-only lock); AT-092's v27_message_fts_backlog follows.
// v28_runtime_install (M6.T16): `runtime_install` (one row per installed runtime component, RuntimeInstaller); was
//                       `v16_runtime_install` on m6/sandbox (dev containers ran it), renumbered by merge order (renamed).
// v29_skill_flags (M7.T12): `skill` (architecture §5.1: name, path, enabled, manifest_json, trust, script_policy) + the
//                       M7.T12 flags apply_all, content_hash, embedding; body in Migrations+Skills.swift (after v28_runtime_install).
// v30_photo_lineage (M4.T09): `artifact_version.operation` (R-287 AC4); after v29_skill_flags.
// v31_image_description (M9.T02, NFR-A5): `image_description` (picture descriptions by content hash); after v30.
// The frozen DDL of the migrated schema (every migration) is `Packages/Storage/Schema/v1_core.sql`
// (MigrationV1Tests compares; `tools/fixtures/gen-chats.py` executes it and records every identifier).
import Foundation
import GRDB

public enum Migrations {
    /// Every migration identifier, in order.
    public static let identifiers = ["v1_core", "v2_think_harder", "v3_tool_permission", "v4_unread", "v5_hardware_profile", "v6_network_activity", "v7_catalog_state", "v8_model_install", "v9_download", "v10_consent", "v11_chunks_vec", "v12_pending_request", "v13_artifact", "v14_files_m6", "v18_memory", "v19_memory_suggestion", "v20_projects", "v21_voice_recording", "v22_mcp_tools", "v24_import_record", "v26_photo_media_job", "v27_message_fts_backlog", "v28_runtime_install", "v29_skill_flags", "v30_photo_lineage", "v31_image_description", "v32_video_run_history", "v33_library_fts"]

    /// M8.T01 renumber safety: identifiers a migration had in an earlier build (`new id: [old ids]`). A database that
    /// recorded an old id is neither refused as newer data nor migrated twice: the new id is registered with GRDB's
    /// `merging:` and its body is skipped when an old id was applied (the bodies are identical by rule). When a merge
    /// renumbers a migration that any build ever ran (Release, try-out or a dev container), add the pair here; the
    /// lock test (`MigrationRunnerTests`, `fixtures/chats/db/migrations.lock`) fails until you do.
    public static let renamed: [String: Set<String>] = [
        "v3_tool_permission": ["v2_tool_permission"],  // M1 merge renumber; the M1-era Release container has v2_…
        "v28_runtime_install": ["v16_runtime_install"],  // M6.T16 merge renumber; m6/sandbox dev containers have v16_…
        "v32_video_run_history": ["v31_video_run_history"],  // M5 merge renumber (main's v31_image_description); m5/video dev containers
        "v33_library_fts": ["v32_library_fts"],  // M5 merge renumber; m5/video dev containers have v32_library_fts
    ]

    /// The newest identifier this build knows.
    public static var head: String { identifiers[identifiers.count - 1] }

    /// Applied identifiers this build does not know (neither registered nor a `renamed` old id): newer data.
    public static func unknownIdentifiers(in applied: Set<String>) -> Set<String> {
        applied.subtracting(identifiers).subtracting(renamed.values.joined())
    }

    /// Registers `id`, merging its old ids (`renamed`); the body runs only when none of them was applied.
    static func register(_ migrator: inout DatabaseMigrator, _ id: String, _ body: @escaping @Sendable (Database) throws -> Void) {
        migrator.registerMigration(id, merging: renamed[id] ?? []) { db, merged in
            if merged.isEmpty { try body(db) }
        }
    }

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1_core", migrate: v1Core)
        migrator.registerMigration("v2_think_harder", migrate: v2ThinkHarder)
        register(&migrator, "v3_tool_permission", v3ToolPermission)  // M8.T01: merges v2_tool_permission
        migrator.registerMigration("v4_unread", migrate: v4Unread)
        migrator.registerMigration("v5_hardware_profile", migrate: v5HardwareProfile)
        migrator.registerMigration("v6_network_activity", migrate: v6NetworkActivity)
        migrator.registerMigration("v7_catalog_state", migrate: v7CatalogState)
        migrator.registerMigration("v8_model_install", migrate: v8ModelInstall)
        migrator.registerMigration("v9_download", migrate: v9Download)
        migrator.registerMigration("v10_consent", migrate: v10Consent)
        migrator.registerMigration("v11_chunks_vec", migrate: ChunkTables.v11ChunksVec)
        migrator.registerMigration("v12_pending_request", migrate: v12PendingRequest)
        migrator.registerMigration("v13_artifact", migrate: v13Artifact)
        migrator.registerMigration("v14_files_m6", migrate: v14FilesM6)
        migrator.registerMigration("v18_memory", migrate: v18Memory)  // M8.T02 (Migrations+Memory.swift); renumber at merge
        migrator.registerMigration("v19_memory_suggestion", migrate: v19MemorySuggestion)  // M8.T03 (Migrations+Memory.swift)
        migrator.registerMigration("v20_projects", migrate: v20Projects)  // M8.T04 (Migrations+Projects.swift)
        migrator.registerMigration("v21_voice_recording", migrate: v21VoiceRecording)  // M3.T03
        migrator.registerMigration("v22_mcp_tools", migrate: v22McpTools)  // M7.T06 (Migrations+MCP.swift); renumber at merge
        migrator.registerMigration("v24_import_record", migrate: v24ImportRecord)  // M8.T06 (Migrations+Import.swift)
        migrator.registerMigration("v26_photo_media_job", migrate: v26PhotoMediaJob)  // M4.T04
        migrator.registerMigration("v27_message_fts_backlog", migrate: v27MessageFTSBacklog)  // AT-092 (Migrations+FTSBacklog.swift)
        register(&migrator, "v28_runtime_install", v28RuntimeInstall)  // M6.T16 (D-026): merges v16_runtime_install
        migrator.registerMigration("v29_skill_flags", migrate: v29SkillFlags)  // M7.T12 (Migrations+Skills.swift)
        migrator.registerMigration("v30_photo_lineage", migrate: v30PhotoLineage)  // M4.T09 (Migrations+Lineage.swift)
        migrator.registerMigration("v31_image_description", migrate: v31ImageDescription)  // M9.T02 (Migrations+ImageDescription.swift)
        register(&migrator, "v32_video_run_history", v32VideoRunHistory)  // M5.T08; merges v31_video_run_history (main took v31)
        register(&migrator, "v33_library_fts", v33LibraryFTS)  // M5.T13 (Migrations+Library.swift); merges v32_library_fts
        return migrator
    }

    /// M4.T04 (R-291): the helper launch that runs a job (a `running` row of another instance is `lost`) and the
    /// job's place in the one-at-a-time queue (1 = running or next; recomputed on every state change).
    static func v26PhotoMediaJob(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE media_job ADD COLUMN engine_instance_id TEXT;
            ALTER TABLE media_job ADD COLUMN position INTEGER;
            CREATE INDEX media_job_queue ON media_job(state, position);
            """)
    }

    /// M1.T15: Think harder per chat (R-007 AC4), restored when the chat is reopened; new chats default off.
    static func v2ThinkHarder(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE chat ADD COLUMN think_harder BOOLEAN NOT NULL DEFAULT 0")
    }

    /// M1.T19 (R-010 AC3): a reply finished while the chat was not on screen (sidebar dot + bold); cleared on open.
    static func v4Unread(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE chat ADD COLUMN unread BOOLEAN NOT NULL DEFAULT 0")
    }

    static func v1Core(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE chat (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              title_state TEXT NOT NULL DEFAULT 'pending' CHECK (title_state IN ('pending', 'auto', 'user')),
              mode TEXT NOT NULL DEFAULT 'normal' CHECK (mode IN ('normal', 'evil')),
              project_id TEXT,
              pinned BOOLEAN NOT NULL DEFAULT 0,
              archived_at DOUBLE,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL,
              leaf_message_id TEXT REFERENCES message(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
              memory_enabled BOOLEAN NOT NULL DEFAULT 1,
              tools_json TEXT,
              model_slot_snapshot TEXT,
              source TEXT NOT NULL DEFAULT 'local' CHECK (source IN ('local', 'chatgpt', 'claude', 'antichat')),
              source_id TEXT,
              import_notice TEXT
            );
            CREATE INDEX chat_sidebar ON chat(archived_at, pinned, updated_at);

            CREATE TABLE message (
              id TEXT PRIMARY KEY NOT NULL,
              chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
              parent_id TEXT REFERENCES message(id) ON DELETE CASCADE,
              active_child_id TEXT REFERENCES message(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
              position INTEGER NOT NULL DEFAULT 0,
              role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system_note')),
              status TEXT NOT NULL DEFAULT 'done'
                CHECK (status IN ('pending', 'streaming', 'done', 'interrupted', 'error')),
              model_id TEXT,
              engine TEXT,
              usage_json TEXT,
              provenance_json TEXT,
              context_summary TEXT,
              summary_of_ids TEXT,
              error_code TEXT,
              created_at DOUBLE NOT NULL,
              source_id TEXT,
              recovered BOOLEAN NOT NULL DEFAULT 0,
              UNIQUE (chat_id, source_id)
            );
            CREATE INDEX message_chat ON message(chat_id, created_at);
            CREATE INDEX message_parent ON message(parent_id, position);
            CREATE INDEX message_status ON message(status) WHERE status IN ('pending', 'streaming');

            CREATE TABLE message_part (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
              idx INTEGER NOT NULL,
              kind TEXT NOT NULL CHECK (kind IN ('text', 'reasoning', 'tool_call', 'tool_result', 'image', 'file',
                                                 'audio', 'citation', 'activity')),
              body TEXT NOT NULL DEFAULT '',
              untrusted BOOLEAN NOT NULL DEFAULT 0,
              UNIQUE (message_id, idx)
            );

            CREATE TABLE file_blob (
              id TEXT PRIMARY KEY NOT NULL,
              sha256 TEXT NOT NULL UNIQUE,
              size INTEGER NOT NULL,
              path TEXT NOT NULL,
              created_at DOUBLE NOT NULL,
              origin TEXT NOT NULL CHECK (origin IN ('upload', 'generated', 'import'))
            );

            CREATE TABLE attachment (
              id TEXT PRIMARY KEY NOT NULL,
              message_id TEXT REFERENCES message(id) ON DELETE CASCADE,
              blob_id TEXT NOT NULL REFERENCES file_blob(id) ON DELETE RESTRICT,
              display_name TEXT NOT NULL,
              uti TEXT NOT NULL,
              pages INTEGER,
              ocr_state TEXT NOT NULL DEFAULT 'none' CHECK (ocr_state IN ('none', 'pending', 'done', 'failed')),
              excerpt_policy TEXT NOT NULL DEFAULT 'whole' CHECK (excerpt_policy IN ('whole', 'excerpt')),
              created_at DOUBLE NOT NULL
            );
            CREATE INDEX attachment_message ON attachment(message_id);
            CREATE INDEX attachment_blob ON attachment(blob_id);

            CREATE TABLE draft (
              chat_id TEXT PRIMARY KEY NOT NULL,
              text TEXT NOT NULL DEFAULT '',
              attachments_json TEXT,
              updated_at DOUBLE NOT NULL
            );

            CREATE TABLE feedback (
              message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
              kind TEXT NOT NULL CHECK (kind IN ('liked', 'disliked', 'refused', 'report')),
              note TEXT,
              created_at DOUBLE NOT NULL,
              PRIMARY KEY (message_id, kind)
            );

            CREATE TABLE media_job (
              id TEXT PRIMARY KEY NOT NULL,
              chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
              message_id TEXT REFERENCES message(id) ON DELETE SET NULL,
              kind TEXT NOT NULL,
              spec_json TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'queued'
                CHECK (state IN ('queued', 'running', 'done', 'blocked', 'failed', 'cancelled', 'lost')),
              progress DOUBLE NOT NULL DEFAULT 0,
              eta_s DOUBLE,
              created_at DOUBLE NOT NULL,
              started_at DOUBLE,
              finished_at DOUBLE,
              error_code TEXT
            );
            CREATE INDEX media_job_state ON media_job(state);

            CREATE TABLE download (
              id TEXT PRIMARY KEY NOT NULL,
              file_sha256 TEXT NOT NULL,
              url TEXT NOT NULL,
              bytes_done INTEGER NOT NULL DEFAULT 0,
              bytes_total INTEGER,
              state TEXT NOT NULL DEFAULT 'queued',
              retries INTEGER NOT NULL DEFAULT 0,
              chunk_map TEXT,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL
            );

            CREATE TABLE local_counter (
              key TEXT PRIMARY KEY NOT NULL,
              value INTEGER NOT NULL DEFAULT 0
            );

            -- R-210: a chat's mode is immutable once it has a message (P-platform-06).
            CREATE TRIGGER chat_mode_locked BEFORE UPDATE OF mode ON chat
              WHEN old.mode <> new.mode AND EXISTS (SELECT 1 FROM message WHERE chat_id = old.id)
              BEGIN SELECT RAISE(ABORT, 'chat.mode is immutable after the first message'); END;
            -- `draft.chat_id` is a chat id or `new`, so it carries no foreign key; drop drafts with their chat.
            CREATE TRIGGER chat_draft_cleanup AFTER DELETE ON chat
              BEGIN DELETE FROM draft WHERE chat_id = old.id; END;

            -- ⌘K full-text search over text parts only (P-shell-05). The view is the external content, so
            -- `INSERT INTO message_fts(message_fts) VALUES('rebuild')` re-reads exactly the indexed rows.
            CREATE VIEW message_text AS SELECT id, body FROM message_part WHERE kind = 'text';
            CREATE VIRTUAL TABLE message_fts USING fts5(
              body, content='message_text', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER message_part_fts_ai AFTER INSERT ON message_part WHEN new.kind = 'text'
              BEGIN INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body); END;
            CREATE TRIGGER message_part_fts_ad AFTER DELETE ON message_part WHEN old.kind = 'text'
              BEGIN INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body); END;
            CREATE TRIGGER message_part_fts_au AFTER UPDATE OF body, kind ON message_part
              BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) SELECT 'delete', old.id, old.body WHERE old.kind = 'text';
                INSERT INTO message_fts(rowid, body) SELECT new.id, new.body WHERE new.kind = 'text';
              END;
            """)
        try db.create(virtualTable: "chat_fts", using: FTS5()) { t in
            t.synchronize(withTable: "chat")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("title")
        }
    }

    static func v3ToolPermission(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE tool_permission (
              tool_key TEXT NOT NULL,
              scope TEXT NOT NULL CHECK (scope IN ('global', 'chat')),
              chat_key TEXT NOT NULL DEFAULT '',
              policy TEXT NOT NULL CHECK (policy IN ('always', 'ask', 'block')),
              updated_at DOUBLE NOT NULL,
              PRIMARY KEY (tool_key, scope, chat_key)
            )
            """)
    }

    /// M2.T01 (R-200 AC6): the cached hardware profile; re-probed when `os_build` changes or W moves > 2 %.
    static func v5HardwareProfile(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE hardware_profile (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              os_build TEXT NOT NULL,
              chip TEXT NOT NULL,
              gpu_cores INTEGER,
              ram INTEGER NOT NULL,
              w DOUBLE,
              b DOUBLE NOT NULL,
              tier TEXT NOT NULL,
              speed_class TEXT NOT NULL,
              probed_at DOUBLE NOT NULL,
              profile_json TEXT NOT NULL
            )
            """)
    }

    /// M2.T02 (R-297 AC2): one row per gated request (Settings → Privacy & Data → Network activity, M2.T03).
    static func v6NetworkActivity(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE network_activity (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts DOUBLE NOT NULL,
              category TEXT NOT NULL,
              host TEXT NOT NULL,
              bytes INTEGER NOT NULL DEFAULT 0,
              outcome TEXT NOT NULL
            );
            CREATE INDEX network_activity_ts ON network_activity(ts);
            """)
    }

    /// M2.T05 (R-220, NFR-SEC7; architecture §5.1): the catalog's rollback high-water mark and last-good copy.
    /// One row (id = 1).
    static func v7CatalogState(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE catalog_state (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              high_water INTEGER NOT NULL,
              last_good_path TEXT,
              fetched_at DOUBLE,
              expires_at DOUBLE,
              status TEXT NOT NULL DEFAULT 'ok'
            )
            """)
    }

    /// M2.T06 (R-222, R-295; architecture §5.1): what is installed per slot (pack × mode × role) and the Advanced
    /// overrides. `previous_manifest_sha` keeps the rollback window (E.2.6 updates step 4).
    static func v8ModelInstall(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE model_install (
              slot TEXT PRIMARY KEY,
              catalog_entry_id TEXT NOT NULL,
              manifest_sha TEXT NOT NULL,
              state TEXT NOT NULL,
              previous_manifest_sha TEXT,
              installed_at DOUBLE
            );
            CREATE TABLE model_override (
              pack TEXT NOT NULL,
              mode TEXT NOT NULL,
              model_id TEXT NOT NULL,
              PRIMARY KEY (pack, mode)
            );
            """)
    }

    /// M2.T08 (R-204, R-220 AC3; blueprint E §E.2.5): the download queue's own columns on v1's `download` row:
    /// the pack and queue priority (InstallQueue order), the catalog model, every source URL in order (JSON; `url`
    /// stays the first), the optional chunk hashes (JSON), why a paused job is paused (`user` / `system`) and the
    /// copy key of the last error.
    /// M2.T17 (R-211 AC1–AC3): one row per accepted version of the Evil terms. A changed `EvilTerms.version`
    /// (the copy of `onb.3.body` + `onb.3.adult` changed) has no row, so Evil counts as not consented.
    /// M2.T24 (R-238 AC2): a media request waiting for its pack (InstallCard → install → re-run in that chat).
    /// M4.T10 (G-025): produced files and their versions (architecture §5.1 `artifact` / `artifact_version`). M1 never
    /// created them; FileCard / SidePanel version labels read these rows. `kind` is free text: M6.T01 extends the set.
    static func v21VoiceRecording(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE file_blob_v21 (
              id TEXT PRIMARY KEY NOT NULL,
              sha256 TEXT NOT NULL UNIQUE,
              size INTEGER NOT NULL,
              path TEXT NOT NULL,
              created_at DOUBLE NOT NULL,
              origin TEXT NOT NULL CHECK (origin IN ('upload', 'generated', 'import', 'recording'))
            );
            INSERT INTO file_blob_v21 (id, sha256, size, path, created_at, origin)
              SELECT id, sha256, size, path, created_at, origin FROM file_blob;
            DROP TABLE file_blob;
            ALTER TABLE file_blob_v21 RENAME TO file_blob;
            CREATE TABLE recording (
              id TEXT PRIMARY KEY NOT NULL,
              chat_id TEXT REFERENCES chat(id) ON DELETE SET NULL,
              created_at DOUBLE NOT NULL,
              duration_ms INTEGER NOT NULL,
              transcript TEXT NOT NULL,
              file_blob_id TEXT NOT NULL REFERENCES file_blob(id) ON DELETE RESTRICT,
              language TEXT NOT NULL,
              engine TEXT NOT NULL CHECK (engine IN ('parakeet', 'whisperkit', 'speechAnalyzer'))
            );
            CREATE INDEX recording_created ON recording(created_at);
            """)
    }

    /// M5.T08 (R-046 AC2, G-046): finished video jobs, the estimator's local history (VideoHistory: median of
    /// actual ÷ estimated over the last 5 runs per preset). Never written for an incognito chat.
    static func v32VideoRunHistory(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE video_run_history (
              id TEXT PRIMARY KEY NOT NULL,
              preset_key TEXT NOT NULL,
              speed_class TEXT NOT NULL,
              estimated_s DOUBLE NOT NULL,
              actual_s DOUBLE NOT NULL,
              created_at DOUBLE NOT NULL
            );
            CREATE INDEX video_run_history_preset ON video_run_history(preset_key, created_at);
            """)
    }

    /// M6.T16 step 3: one row per installed runtime component (`RuntimeInstaller`; generic, M5.T01's video runtime
    /// records here too). `id` = the runtime name (`filetools-runtime`); one installed version per runtime.
    static func v28RuntimeInstall(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE runtime_install (
              id TEXT PRIMARY KEY NOT NULL,
              version TEXT NOT NULL,
              path TEXT NOT NULL,
              sha256 TEXT NOT NULL,
              size_bytes INTEGER NOT NULL DEFAULT 0,
              installed_at DOUBLE NOT NULL
            );
            """)
    }

    static func v14FilesM6(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE attachment ADD COLUMN extract_state TEXT NOT NULL DEFAULT 'none'
              CHECK (extract_state IN ('none', 'reading', 'ready', 'failed', 'encrypted', 'unsupported'));
            ALTER TABLE attachment ADD COLUMN token_count INTEGER;
            ALTER TABLE attachment ADD COLUMN page_map_json TEXT;
            ALTER TABLE attachment ADD COLUMN caption_text TEXT;
            ALTER TABLE attachment ADD COLUMN ocr_text TEXT;
            CREATE TABLE retrieval (
              message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
              chunk_id INTEGER NOT NULL,
              page_ref TEXT,
              rank INTEGER NOT NULL,
              PRIMARY KEY (message_id, chunk_id)
            );
            ALTER TABLE chunk ADD COLUMN page_ref TEXT;
            ALTER TABLE artifact_version ADD COLUMN parent_version_id TEXT REFERENCES artifact_version(id) ON DELETE SET NULL;
            """)
    }

    static func v13Artifact(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE artifact (
              id TEXT PRIMARY KEY NOT NULL,
              chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              created_at DOUBLE NOT NULL
            );
            CREATE INDEX artifact_chat ON artifact(chat_id);
            CREATE TABLE artifact_version (
              id TEXT PRIMARY KEY NOT NULL,
              artifact_id TEXT NOT NULL REFERENCES artifact(id) ON DELETE CASCADE,
              n INTEGER NOT NULL,
              blob_id TEXT NOT NULL REFERENCES file_blob(id) ON DELETE RESTRICT,
              spec_json TEXT,
              created_by_message_id TEXT REFERENCES message(id) ON DELETE SET NULL,
              created_at DOUBLE NOT NULL,
              UNIQUE (artifact_id, n)
            );
            """)
    }

    static func v12PendingRequest(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE pending_request (
              assistant_id TEXT PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
              chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
              user_message_id TEXT NOT NULL,
              pack TEXT NOT NULL,
              created_at DOUBLE NOT NULL
            );
            CREATE INDEX pending_request_chat ON pending_request(chat_id);
            """)
    }

    static func v10Consent(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE consent (
              kind TEXT NOT NULL,
              version TEXT NOT NULL,
              accepted_at REAL NOT NULL,
              adult_self_declared INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (kind, version)
            );
            """)
    }

    static func v9Download(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE download ADD COLUMN pack TEXT;
            ALTER TABLE download ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE download ADD COLUMN model_id TEXT;
            ALTER TABLE download ADD COLUMN sources TEXT;
            ALTER TABLE download ADD COLUMN chunk_sha TEXT;
            ALTER TABLE download ADD COLUMN pause_reason TEXT;
            ALTER TABLE download ADD COLUMN error TEXT;
            CREATE INDEX download_sha ON download(file_sha256);
            """)
    }
}
