// Chat rows: create, rename, pin, archive, delete, sidebar observation (architecture §5.1 `chat`, §6 readers).
import Foundation
import GRDB
import Synchronization

public struct ChatRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    @discardableResult
    public func create(title: String = "", mode: ChatMode = .normal, projectID: String? = nil) throws -> ChatRecord {
        let chat = ChatRecord(title: title, titleState: title.isEmpty ? .pending : .user, mode: mode,
                              projectID: projectID)
        try database.write { db in try chat.insert(db) }
        return chat
    }

    public func chat(_ id: String) throws -> ChatRecord? {
        try database.read { db in try ChatRecord.fetchOne(db, key: id) }
    }

    /// Sidebar order: pinned first, then most recently updated; archived chats excluded.
    public static func sidebarRequest() -> QueryInterfaceRequest<ChatRecord> {
        ChatRecord
            .filter(ChatRecord.Columns.archivedAt == nil)
            .order(ChatRecord.Columns.pinned.desc, ChatRecord.Columns.updatedAt.desc, ChatRecord.Columns.id.desc)
    }

    public func sidebar(limit: Int? = nil) throws -> [ChatRecord] {
        try database.read { db in try Self.sidebarRequest().limit(limit ?? Int.max).fetchAll(db) }
    }

    /// A `ValueObservation` of the sidebar list (start it with `start(in: database.reader, …)`).
    public func observeSidebar() -> ValueObservation<ValueReducers.Fetch<[ChatRecord]>> {
        ValueObservation.trackingConstantRegion { db in try Self.sidebarRequest().fetchAll(db) }  // refetched off the writer
    }

    public func archived() throws -> [ChatRecord] {
        try database.read { db in
            try ChatRecord.filter(ChatRecord.Columns.archivedAt != nil)
                .order(ChatRecord.Columns.archivedAt.desc).fetchAll(db)
        }
    }

    public func rename(_ id: String, title: String, state: TitleState = .user) throws {
        try update(id) { $0.title = title; $0.titleState = state }
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws { try update(id) { $0.pinned = pinned } }

    public func setArchived(_ id: String, _ archived: Bool) throws {
        try update(id) { $0.archivedAt = archived ? Date() : nil }
    }

    /// Fails with a database error once the chat has a message (R-210, `chat_mode_locked` trigger).
    public func setMode(_ id: String, _ mode: ChatMode) throws { try update(id) { $0.mode = mode } }

    /// M1.T15 (`v2_think_harder`): the chat's Think harder toggle; false for a new or unknown chat.
    public func thinkHarder(_ id: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT think_harder FROM chat WHERE id = ?", arguments: [id]) ?? false
        }
    }

    /// Sets the chat's Think harder toggle. Not an edit of the chat: `updated_at` (sidebar order) is kept.
    /// Returns false when the chat does not exist (yet).
    @discardableResult
    public func setThinkHarder(_ id: String, _ on: Bool) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE chat SET think_harder = ? WHERE id = ?", arguments: [on, id])
            return db.changesCount > 0
        }
    }

    /// M1.T17: the chat's sticky tool chips (`chat.tools_json`, a JSON array of composer menu-item ids); nil when none.
    public func toolsJSON(_ id: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT tools_json FROM chat WHERE id = ?", arguments: [id])
        }
    }

    /// Sets the chat's sticky tool chips. Not an edit of the chat: `updated_at` (sidebar order) is kept.
    /// Returns false when the chat does not exist (yet).
    @discardableResult
    public func setToolsJSON(_ id: String, _ json: String?) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE chat SET tools_json = ? WHERE id = ?", arguments: [json, id])
            return db.changesCount > 0
        }
    }

    /// M1.T19 step 1: a new chat whose title is the prompt's first characters until the auto title arrives
    /// (`title_state = pending`).
    @discardableResult
    public func create(temporaryTitle: String, mode: ChatMode = .normal) throws -> ChatRecord {
        let chat = ChatRecord(title: temporaryTitle, titleState: .pending, mode: mode)
        try database.write { db in try chat.insert(db) }
        return chat
    }

    /// M1.T19 step 2: the auto title replaces a pending one; a user rename (`user`) is never overwritten. Not an
    /// edit of the chat (`updated_at` kept). Returns false when nothing changed.
    @discardableResult
    public func applyAutoTitle(_ id: String, title: String) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE chat SET title = ?, title_state = 'auto' WHERE id = ? AND title_state = 'pending'",
                           arguments: [title, id])
            return db.changesCount > 0
        }
    }

    /// `applyAutoTitle` without waiting for the writer (the title job lands on the main thread mid-stream).
    /// `applied` gets whether it changed the row (false: renamed meanwhile, or the write failed), on the writer's queue.
    public func applyAutoTitleLater(_ id: String, title: String, applied: (@Sendable (Bool) -> Void)? = nil) {
        let changed = Mutex(false)
        database.writeLater("auto title", { db in
            try db.execute(sql: "UPDATE chat SET title = ?, title_state = 'auto' WHERE id = ? AND title_state = 'pending'",
                           arguments: [title, id])
            changed.withLock { $0 = db.changesCount > 0 }
        }, completion: { result in
            if case .success = result { applied?(changed.withLock { $0 }) } else { applied?(false) }
        })
    }

    /// VQ round 65 (S-09) / AT-NFR-S3: the first prompt was edited; the chat takes `title` as its temporary title again
    /// (`pending`, so the auto title is asked for anew), enqueued on the writer (the edit lands on the main thread). The
    /// statement never touches a title the user set (`title_state 'user'`). `applied` gets whether the row changed.
    public func retitlePendingLater(_ id: String, title: String, applied: (@Sendable (Bool) -> Void)? = nil) {
        let changed = Mutex(false)
        let now = Date()
        database.writeLater("retitle", { db in
            try db.execute(sql: """
                UPDATE chat SET title = ?, title_state = 'pending', updated_at = ? WHERE id = ? AND title_state != 'user'
                """, arguments: [title, now, id])
            changed.withLock { $0 = db.changesCount > 0 }
        }, completion: { result in
            if case .success = result { applied?(changed.withLock { $0 }) } else { applied?(false) }
        })
    }

    /// `setUnread` without waiting for the writer (opening a chat on the main thread).
    public func setUnreadLater(_ id: String, _ unread: Bool) {
        database.writeLater("unread") { db in
            try db.execute(sql: "UPDATE chat SET unread = ? WHERE id = ? AND unread != ?", arguments: [unread, id, unread])
        }
    }

    /// M1.T19 step 4 (`v4_unread`): the sidebar's unread dot. `updated_at` is kept.
    @discardableResult
    public func setUnread(_ id: String, _ unread: Bool) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE chat SET unread = ? WHERE id = ? AND unread != ?", arguments: [unread, id, unread])
            return db.changesCount > 0
        }
    }

    /// Deletes the chat with every message, part, attachment row, feedback, media job and draft (cascade).
    public func delete(_ id: String) throws {
        _ = try database.write { db in try ChatRecord.deleteOne(db, key: id) }
    }

    /// Title search (⌘K, P-shell-05): FTS5 prefix match on `chat_fts`, best first.
    public func searchTitles(_ query: String, limit: Int = 50) throws -> [ChatRecord] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try database.read { db in
            try ChatRecord.fetchAll(db, sql: """
                SELECT chat.* FROM chat_fts JOIN chat ON chat.rowid = chat_fts.rowid
                WHERE chat_fts MATCH ? ORDER BY bm25(chat_fts) LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    private func update(_ id: String, _ change: (inout ChatRecord) -> Void) throws {
        try database.write { db in
            guard var chat = try ChatRecord.fetchOne(db, key: id) else { throw StorageError.notFound("chat \(id)") }
            change(&chat)
            chat.updatedAt = Date()
            try chat.update(db)
        }
    }
}
