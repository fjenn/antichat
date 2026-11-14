// AT-092 AC2 (R-092): the import writes chats without their full-text rows (the v25 triggers skip an open
// `message_fts_backlog` window), so a 1 GB export is usable as soon as its rows are in; this pass then indexes the
// window in short write transactions (a live chat's writes interleave) with real progress, and is resumed at launch
// (an import that crashed leaves an open window: `resume` closes it first). Search shows imported chats as the pass
// reaches them.
import AntiChatFoundation
import Foundation
import GRDB

public struct MessageSearchBacklog: Sendable {
    public let database: AppDatabase
    /// Rows per write transaction (≈ 20–60 ms of FTS work each on an M-series Mac).
    public static let batch = 2_000

    public init(database: AppDatabase) { self.database = database }

    public struct Status: Sendable, Equatable {
        public var pending: Int64
        public var total: Int64
        public var fraction: Double { total > 0 ? min(1, Double(total - pending) / Double(total)) : 1 }
        public var isDone: Bool { pending <= 0 }
    }

    /// Opens a window (or joins the open one): text parts inserted from now on skip the FTS triggers.
    public static func begin(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts_backlog WHERE to_id IS NULL") == 0 else { return }
        let max = try Int64.fetchOne(db, sql: "SELECT ifnull(max(id), 0) FROM message_part") ?? 0
        try db.execute(sql: "INSERT INTO message_fts_backlog(from_id, done_id, to_id, created_at) VALUES (?, ?, NULL, ?)",
                       arguments: [max, max, Date().timeIntervalSince1970])
    }

    /// Closes the open window at the current max id (later rows are indexed by the triggers again).
    public static func end(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE message_fts_backlog SET to_id = (SELECT ifnull(max(id), 0) FROM message_part) WHERE to_id IS NULL
            """)
    }

    public func begin() throws { try database.write { try Self.begin($0) } }
    public func end() throws { try database.write { try Self.end($0) } }

    public func status() throws -> Status {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT from_id, done_id, ifnull(to_id, (SELECT ifnull(max(id), 0) FROM message_part)) AS hi
                FROM message_fts_backlog
                """)
            var s = Status(pending: 0, total: 0)
            for r in rows {
                let from: Int64 = r["from_id"], done: Int64 = r["done_id"], hi: Int64 = r["hi"]
                s.total += max(0, hi - from)
                s.pending += max(0, hi - done)
            }
            return s
        }
    }

    /// Indexes one batch of the oldest window; returns false when nothing is left. A closed window is deleted when
    /// done; an open one (an import still running) only advances.
    @discardableResult
    public func step(batch: Int = MessageSearchBacklog.batch) throws -> Bool {
        try database.write { db in
            guard let w = try Row.fetchOne(db, sql: "SELECT id, done_id, to_id FROM message_fts_backlog ORDER BY id LIMIT 1")
            else { return false }
            let id: Int64 = w["id"], done: Int64 = w["done_id"], to: Int64? = w["to_id"]
            let hi = try to ?? (Int64.fetchOne(db, sql: "SELECT ifnull(max(id), 0) FROM message_part") ?? 0)
            let upto = min(hi, done + Int64(batch))
            if upto > done {
                try db.execute(sql: """
                    INSERT INTO message_fts(rowid, body)
                    SELECT id, body FROM message_part WHERE kind = 'text' AND id > ? AND id <= ?
                    """, arguments: [done, upto])
                try db.execute(sql: "UPDATE message_fts_backlog SET done_id = ? WHERE id = ?", arguments: [upto, id])
            }
            if let to, upto >= to {
                try db.execute(sql: "DELETE FROM message_fts_backlog WHERE id = ?", arguments: [id])
                return true
            }
            return upto > done
        }
    }

    /// Runs the windows to the end (an open one: up to the rows written so far) (`progress` after each batch); stops early when `isCancelled`.
    public func run(progress: (Status) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        while !isCancelled() {
            let more = try step()
            progress(try status())
            if !more { break }
        }
    }

    /// Launch: no import runs yet, so an open window is a crashed import's — close it; then run the pass in the
    /// background. Returns immediately.
    public static func resume(_ database: AppDatabase) {
        guard !database.isInMemory else { return }
        let backlog = MessageSearchBacklog(database: database)
        guard (try? backlog.status().isDone) == false else { return }
        try? backlog.end()
        Thread.detachNewThread {
            Thread.current.qualityOfService = .utility
            do { try backlog.run() } catch { AppLog.log(.store, .error, "fts backlog: \(error)") }
        }
    }
}
