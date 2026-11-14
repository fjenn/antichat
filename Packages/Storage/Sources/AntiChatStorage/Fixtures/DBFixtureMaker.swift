// M8.T01 step 0 (DEBUG): one fixture database per shipped schema version, `fixtures/chats/db/<identifier>.sqlite`
// (`antichat-cli db make-fixture`, wrapped by tools/fixtures/make-db-fixture.py). The file is migrated with this
// build's migrator up to `upTo`, then seeded deterministically: 20 chats with branches (an edited user turn and a
// regenerated reply), 2 images, a draft, feedback, a media job, a download, and one row in every other table that
// exists at that version. `future` appends `v999_future` to `grdb_migrations` (the newer-data fixture).
// Single-file `journal_mode=DELETE`, so the committed fixture is one file.
#if DEBUG || ANTICHAT_PERF_HARNESS
import Foundation
import GRDB

public enum DBFixtureMaker {
    public static let futureIdentifier = "v999_future"

    /// The M1-era Release container (`v1_core` + `v2_tool_permission`, before the M1 merge renumbered it to
    /// `v3_tool_permission`): the shape the owner's `~/Library/Application Support/AntiChat` has (schema checked
    /// against it read-only on 2026-11-04). Exercises `Migrations.renamed`.
    public static func makeLegacyM1(at url: URL, seed: UInt64 = 20_261_030) throws {
        try make(upTo: "v1_core", at: url, seed: seed) { db in
            try Migrations.v3ToolPermission(db)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v2_tool_permission')")
        }
    }

    public static func make(upTo: String, at url: URL, seed: UInt64 = 20_261_030, future: Bool = false,
                            extra: ((Database) throws -> Void)? = nil) throws {
        guard Migrations.identifiers.contains(upTo) else { throw StorageError.notFound(upTo) }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: url.path + suffix) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { try VecLoader.load($0) }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        var migrator = Migrations.migrator()
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: upTo)
        try queue.write { db in
            try extra?(db)
            try ChunkTables.ensureVectorTable(db)
            try seedRows(db, seed: seed)
            if future { try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [futureIdentifier]) }
        }
        try queue.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
        try queue.close()
    }

    /// A tiny deterministic generator (SplitMix64), so every run writes the same rows.
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    static let topics = ["sourdough", "tax return", "trip to Lisbon", "Swift concurrency", "garden beds", "piano practice",
                         "marathon plan", "wedding toast", "budget sheet", "cat allergy"]

    static func seedRows(_ db: Database, seed: UInt64) throws {
        var r = Rand(state: seed)
        let t0 = 1_793_000_000.0  // 2026-10-26, fixed
        func id(_ p: String, _ n: Int) -> String { "\(p)-\(seed)-\(n)" }
        var msg = 0
        func message(_ chat: String, parent: String?, role: String, text: String, position: Int, at t: Double) throws -> String {
            msg += 1
            let mid = id("m", msg)
            try db.execute(sql: """
                INSERT INTO message (id, chat_id, parent_id, position, role, status, model_id, created_at)
                VALUES (?, ?, ?, ?, ?, 'done', ?, ?)
                """, arguments: [mid, chat, parent, position, role, role == "assistant" ? "chat-0.8b" : nil, t])
            try db.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES (?, 0, 'text', ?)",
                           arguments: [mid, text])
            if let parent { try db.execute(sql: "UPDATE message SET active_child_id = ? WHERE id = ?", arguments: [mid, parent]) }
            return mid
        }
        for c in 0..<20 {
            let chat = id("c", c)
            let topic = r.pick(topics)
            let t = t0 + Double(c) * 3600
            try db.execute(sql: """
                INSERT INTO chat (id, title, title_state, mode, pinned, created_at, updated_at)
                VALUES (?, ?, 'auto', ?, ?, ?, ?)
                """, arguments: [chat, "About \(topic) \(c)", c == 19 ? "evil" : "normal", c == 0, t, t + 60])
            var parent: String?
            var leaf: String?
            for turn in 0..<(2 + Int(r.next() % 3)) {
                let u = try message(chat, parent: parent, role: "user", text: "Question \(turn) on \(topic)?", position: 0, at: t + Double(turn) * 10)
                let a = try message(chat, parent: u, role: "assistant", text: "Answer \(turn) about \(topic) (\(r.next() % 1000)).",
                                    position: 0, at: t + Double(turn) * 10 + 5)
                parent = a
                leaf = a
            }
            if c % 4 == 0, let p = parent {  // a regenerated reply: a second sibling under the last user turn
                let user = try String.fetchOne(db, sql: "SELECT parent_id FROM message WHERE id = ?", arguments: [p])
                leaf = try message(chat, parent: user, role: "assistant", text: "Another take on \(topic).", position: 1, at: t + 50)
            }
            try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?", arguments: [leaf, chat])
        }
        // 2 images (blobs + attachments on the first user turns), a draft, feedback, a media job, a download.
        for i in 0..<2 {
            try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, 68, ?, ?, ?)",
                           arguments: [id("b", i), String(repeating: "\(i)", count: 64), "Media/\(i).png", t0, i == 0 ? "upload" : "generated"])
            try db.execute(sql: """
                INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at) VALUES (?, ?, ?, ?, 'public.png', ?)
                """, arguments: [id("a", i), id("m", 1 + i * 9), id("b", i), "photo-\(i).png", t0])
        }
        try db.execute(sql: "INSERT INTO draft (chat_id, text, updated_at) VALUES (?, 'half a thought', ?)", arguments: [id("c", 1), t0])
        try db.execute(sql: "INSERT INTO feedback (message_id, kind, created_at) VALUES (?, 'liked', ?)", arguments: [id("m", 2), t0])
        try db.execute(sql: "INSERT INTO media_job (id, chat_id, kind, spec_json, state, created_at) VALUES (?, ?, 'image', '{}', 'done', ?)",
                       arguments: [id("j", 0), id("c", 2), t0])
        try db.execute(sql: """
            INSERT INTO download (id, file_sha256, url, state, created_at, updated_at) VALUES (?, ?, 'https://example.invalid/x', 'done', ?, ?)
            """, arguments: [id("d", 0), String(repeating: "d", count: 64), t0, t0])
        try db.execute(sql: "INSERT INTO local_counter (key, value) VALUES ('fixture', 1)")

        // Tables of later versions: one row each when the table exists at this version.
        let later: [(String, String, StatementArguments)] = [
            ("tool_permission", "INSERT INTO tool_permission (tool_key, scope, chat_key, policy, updated_at) VALUES ('get_time', 'global', '', 'always', ?)", [t0]),
            ("hardware_profile", "INSERT INTO hardware_profile (id, os_build, chip, ram, b, tier, speed_class, probed_at, profile_json) VALUES (1, '25A1', 'M4 Max', 128, 100, 'T3', 'S2', ?, '{}')", [t0]),
            ("network_activity", "INSERT INTO network_activity (ts, category, host, bytes, outcome) VALUES (?, 'models', 'huggingface.co', 1024, 'ok')", [t0]),
            ("catalog_state", "INSERT INTO catalog_state (id, high_water, status) VALUES (1, 3, 'ok')", []),
            ("model_install", "INSERT INTO model_install (slot, catalog_entry_id, manifest_sha, state) VALUES ('chat_fast', 'chat-0.8b', 'abc', 'ready')", []),
            ("consent", "INSERT INTO consent (kind, version, accepted_at, adult_self_declared) VALUES ('evil_terms', 'v1', ?, 1)", [t0]),
            ("chunk", "INSERT INTO chunk (source, source_id, chat_id, ord, text, created_at) VALUES ('message', ?, ?, 0, 'Answer 0 about bread', ?)", [id("m", 2), id("c", 0), t0]),
            ("pending_request", "INSERT INTO pending_request (assistant_id, chat_id, user_message_id, pack, created_at) VALUES (?, ?, ?, 'photo', ?)", [id("m", 4), id("c", 0), id("m", 3), t0]),
            ("artifact", "INSERT INTO artifact (id, chat_id, kind, title, created_at) VALUES (?, ?, 'pdf', 'Notes', ?)", [id("art", 0), id("c", 3), t0]),
            ("artifact_version", "INSERT INTO artifact_version (id, artifact_id, n, blob_id, created_at) VALUES (?, ?, 1, ?, ?)", [id("av", 0), id("art", 0), id("b", 1), t0]),
            ("retrieval", "INSERT INTO retrieval (message_id, chunk_id, rank) VALUES (?, 1, 0)", [id("m", 2)]),
            ("memory_topic", "INSERT INTO memory_topic (id, scope, name, created_at, updated_at) VALUES (?, 'global', 'Food', ?, ?)", [id("mt", 0), t0, t0]),
            ("memory_item", "INSERT INTO memory_item (id, topic_id, scope, key, text, origin, source_chat_id, created_at, updated_at) VALUES (?, ?, 'global', 'diet', 'Is vegetarian', 'tool', ?, ?, ?)", [id("mi", 0), id("mt", 0), id("c", 0), t0, t0]),
            ("memory_suggestion", "INSERT INTO memory_suggestion (id, text, topic, created_at) VALUES (?, 'Likes jazz', 'Music', ?)", [id("ms", 0), t0]),
            ("memory_event", "INSERT INTO memory_event (id, item_id, op, after_json, created_at) VALUES (?, ?, 'add', '{}', ?)", [id("me", 0), id("mi", 0), t0]),
            ("project", "INSERT INTO project (id, name, icon, created_at, updated_at) VALUES (?, 'Thesis', 'graduationcap', ?, ?)", [id("p", 0), t0, t0]),
            ("project", "UPDATE chat SET project_id = ? WHERE id = ?", [id("p", 0), id("c", 4)]),
            ("project_instruction", "INSERT INTO project_instruction (project_id, text, updated_at) VALUES (?, 'Answer in formal Dutch.', ?)", [id("p", 0), t0]),
            ("project_file", "INSERT INTO project_file (id, project_id, display_name, size, rel_path, origin, index_state, created_at) VALUES (?, ?, 'notes.md', 12, 'notes.md', 'linked', 'ready', ?)", [id("pf", 0), id("p", 0), t0]),
            ("mcp_server", "INSERT INTO mcp_server (id, name, url_or_cmd, auth_kind, auth_ref, state, tools_hash, last_reviewed_hash, created_at, updated_at) VALUES (?, 'Docs', 'https://mcp.example.invalid/mcp', 'token', 'app.antichat.mcp.fixture', 'connected', 'h1', 'h1', ?, ?)", [id("srv", 0), t0, t0]),
            ("mcp_tool", "INSERT INTO mcp_tool (server_id, name, description, desc_hash, reviewed_hash, updated_at) VALUES (?, 'search_docs', 'Search the docs', 'd1', 'd1', ?)", [id("srv", 0), t0]),
            ("import_record", "INSERT INTO import_record (id, source, external_key, chat_id, external_updated_at, imported_at) VALUES (?, 'chatgpt', 'conv-0', ?, ?, ?)", [id("ir", 0), id("c", 1), t0, t0]),
            ("runtime_install", "INSERT INTO runtime_install (id, version, path, sha256, size_bytes, installed_at) VALUES ('filetools-runtime', '0.1.0', '/fixture/Runtimes/filetools-runtime@0.1.0', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 73400000, ?)", [t0]),
            ("image_description", "INSERT INTO image_description (sha256, text, source, language, updated_at) VALUES ('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'A loaf of bread on a wooden board.', 'auto', 'en', ?)", [t0]),
            ("skill", "INSERT INTO skill (id, name, path, enabled, manifest_json, trust, apply_all, content_hash, created_at, updated_at) VALUES (?, 'meeting-notes', 'meeting-notes', 1, '{\"description\":\"Turn notes into minutes\"}', 'bundled', 0, 'h0', ?, ?)", [id("sk", 0), t0, t0]),
            ("video_run_history", "INSERT INTO video_run_history (id, preset_key, speed_class, estimated_s, actual_s, created_at) VALUES (?, 't2v-480p-short', 'S4', 11.96, 12.4, ?)", [id("vr", 0), t0]),
            // M5.T13: a generated clip with its prompt (library_doc / library_fts fill from the triggers).
            ("library_doc", "INSERT INTO artifact (id, chat_id, kind, title, created_at) VALUES (?, ?, 'video', 'video.mp4', ?)", [id("art", 1), id("c", 5), t0]),
            ("library_doc", "INSERT INTO artifact_version (id, artifact_id, n, blob_id, spec_json, created_at) VALUES (?, ?, 1, ?, '{\"prompt\":\"waves rolling onto a beach\",\"frames\":49,\"fps\":16,\"sound\":false}', ?)", [id("av", 1), id("art", 1), id("b", 1), t0]),
        ]
        for (table, sql, args) in later where try db.tableExists(table) {
            try db.execute(sql: sql, arguments: args)
        }
    }
}
#endif
