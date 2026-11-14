// M2.T16 step 4 (R-244, R-295, R-247): cuts finished user/assistant messages into `chunk` rows and embeds the chunks
// that have no `chunk_vec` row yet, in batches of 32 at `.utility`. Resumable by construction: the work list is
// "finished messages without chunks" and "chunks without vectors", so a quit or a missing model only delays it.
// Works on the persistent database only; incognito chats live in their in-memory store and their jobs are dropped by
// BackgroundJobQueue before reaching here (R-247 AC1).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

public actor BackgroundIndexer {
    public let database: AppDatabase
    public static let source = "message"
    public static let batch = 32

    public init(database: AppDatabase) { self.database = database }

    /// Chunks one finished message (no-op when already chunked, unfinished, or not user/assistant text).
    @discardableResult
    public func index(messageID: String) throws -> Int {
        try database.write { db in try Self.chunk(db, messageID: messageID) }
    }

    /// Messages chunked per write transaction in `catchUp`.
    public static let catchUpPerTransaction = 8

    /// Chunks every finished message that has no chunk yet (catch-up after launch / after every turn,
    /// `antichat-cli index rebuild`). The work list is read once; the chunks are written a few messages per
    /// transaction, so this `.utility` job never holds the one writer for long: the main thread and the streaming saves
    /// queue behind whatever holds it, and a long transaction starved under CPU load stalled the UI (AT-NFR-S3).
    /// `chunk` re-checks each message inside its transaction, so a concurrent pass never chunks one twice.
    @discardableResult
    public func catchUp(limit: Int = .max) throws -> Int {
        let ids = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM message m
                WHERE m.role IN ('user', 'assistant') AND m.status = 'done'
                  AND NOT EXISTS (SELECT 1 FROM chunk c WHERE c.source = 'message' AND c.source_id = m.id)
                ORDER BY m.created_at LIMIT ?
                """, arguments: [limit == .max ? -1 : limit])
        }
        var total = 0
        for start in stride(from: 0, to: ids.count, by: Self.catchUpPerTransaction) {
            let slice = ids[start..<min(start + Self.catchUpPerTransaction, ids.count)]
            total += try database.write { db in try slice.reduce(0) { $0 + (try Self.chunk(db, messageID: $1)) } }
        }
        return total
    }

    static func chunk(_ db: Database, messageID: String) throws -> Int {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT chat_id, created_at FROM message WHERE id = ? AND role IN ('user', 'assistant') AND status = 'done'
            """, arguments: [messageID]) else { return 0 }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chunk WHERE source = ? AND source_id = ?)",
                             arguments: [source, messageID]) == true { return 0 }
        let text = try String.fetchAll(db, sql: """
            SELECT body FROM message_part WHERE message_id = ? AND kind = 'text' ORDER BY idx
            """, arguments: [messageID]).joined(separator: "\n\n")
        let pieces = Chunker.chunks(text)
        for (i, piece) in pieces.enumerated() {
            try db.execute(sql: """
                INSERT INTO chunk(source, source_id, chat_id, ord, text, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [source, messageID, row["chat_id"] as String, i, piece, row["created_at"] as Double])
        }
        return pieces.count
    }

    /// Embeds up to `limit` chunks that have no vector. Returns how many were embedded (0 = done or no model).
    @discardableResult
    public func embedPending(with embedder: any Embedder, limit: Int = 512) async throws -> Int {
        var done = 0
        while done < limit {
            let rows = try await database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT c.id, c.text FROM chunk c
                    WHERE NOT EXISTS (SELECT 1 FROM chunk_vec v WHERE v.rowid = c.id)
                    ORDER BY c.id LIMIT ?
                    """, arguments: [Self.batch])
            }
            guard !rows.isEmpty else { break }
            let vectors = try await embedder.embed(rows.map { $0["text"] as String }, kind: .document)
            guard vectors.count == rows.count else { break }
            try await database.write { db in
                for (row, v) in zip(rows, vectors) where v.count == VecLoader.dimensions {
                    try db.execute(sql: "INSERT OR REPLACE INTO chunk_vec(rowid, embedding) VALUES (?, ?)",
                                   arguments: [row["id"] as Int64, ChunkTables.blob(v)])
                }
            }
            done += rows.count
        }
        return done
    }

    /// Chunks without a vector (status / tests).
    public func pendingCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM chunk c WHERE NOT EXISTS (SELECT 1 FROM chunk_vec v WHERE v.rowid = c.id)
                """) ?? 0
        }
    }

    /// `antichat-cli index rebuild`: drop every chunk (vectors follow by trigger) and chunk again.
    @discardableResult
    public func rebuild() throws -> Int {
        try database.write { db in try db.execute(sql: "DELETE FROM chunk") }
        return try catchUp()
    }
}
