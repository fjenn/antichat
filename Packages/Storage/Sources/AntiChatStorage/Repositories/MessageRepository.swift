// Message rows and parts: streaming upserts (NFR-S2: batched by the caller, ≤ 500 ms / 50 tokens), final write
// (status + usage + provenance + parts in one transaction, architecture §6), launch recovery (R-208), FTS search.
import Foundation
import GRDB

public struct MessageRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func message(_ id: String) throws -> MessageRecord? {
        try database.read { db in try MessageRecord.fetchOne(db, key: id) }
    }

    public func parts(of messageID: String) throws -> [MessagePartRecord] {
        try database.read { db in try Self.parts(of: messageID, db: db) }
    }

    public static func parts(of messageID: String, db: Database) throws -> [MessagePartRecord] {
        try MessagePartRecord.filter(MessagePartRecord.Columns.messageID == messageID)
            .order(MessagePartRecord.Columns.idx).fetchAll(db)
    }

    /// Inserts or replaces part `idx` of `messageID` (the streaming write path).
    public func upsertPart(_ messageID: String, idx: Int, _ part: PartContent) throws {
        try database.write { db in try Self.upsertPart(messageID, idx: idx, part, db: db) }
    }

    public static func upsertPart(_ messageID: String, idx: Int, _ part: PartContent, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO message_part (message_id, idx, kind, body, untrusted) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(message_id, idx) DO UPDATE SET kind = excluded.kind, body = excluded.body,
              untrusted = excluded.untrusted
            """, arguments: [messageID, idx, part.kind, part.body, part.untrusted])
    }

    /// One streaming flush: every changed part plus the status, in one transaction.
    public func flush(_ messageID: String, parts: [(idx: Int, part: PartContent)], status: MessageStatus = .streaming)
        throws
    {
        try database.write { db in
            for (idx, part) in parts { try Self.upsertPart(messageID, idx: idx, part, db: db) }
            try db.execute(sql: "UPDATE message SET status = ? WHERE id = ?", arguments: [status, messageID])
        }
    }

    /// The final write of a turn: parts, status, usage, provenance (R-234) and the chat's `updated_at`, atomically.
    public func finish(
        _ messageID: String, status: MessageStatus, parts: [(idx: Int, part: PartContent)] = [],
        usage: MessageUsage? = nil, provenance: MessageProvenance? = nil, errorCode: String? = nil
    ) throws {
        try database.write { db in
            guard var message = try MessageRecord.fetchOne(db, key: messageID) else {
                throw StorageError.notFound("message \(messageID)")
            }
            for (idx, part) in parts { try Self.upsertPart(messageID, idx: idx, part, db: db) }
            message.status = status
            if let usage { message.usage = usage }
            if let provenance { message.provenance = provenance }
            message.errorCode = errorCode
            try message.update(db)
            try db.execute(sql: "UPDATE chat SET updated_at = ? WHERE id = ?",
                           arguments: [Date().timeIntervalSince1970, message.chatID])
        }
    }

    /// AT-250 c2 (M7 bars): a late citation verdict for a finished reply. When the stored text still starts with
    /// `checked` (the text the checks ran on; a later [Continue] only appends), that part becomes `settled` (markers
    /// removed, words unchanged); the `citations_checking` flag is cleared either way. Returns the new text, or nil
    /// when the message is gone or its text no longer starts with `checked` (the verdict is dropped).
    @discardableResult
    public func settleCitations(_ messageID: String, checked: String, settled: String) throws -> String? {
        try database.write { db in
            guard var message = try MessageRecord.fetchOne(db, key: messageID) else { return nil }
            if message.provenance?.citationsChecking != nil {
                message.provenance?.citationsChecking = nil
                try message.update(db)
            }
            guard var part = try Self.parts(of: messageID, db: db).first(where: { $0.kind == .text }),
                  part.body.hasPrefix(checked) else { return nil }
            let text = settled + part.body.dropFirst(checked.count)
            if text != part.body {
                part.body = text
                try Self.upsertPart(messageID, idx: part.idx, PartContent(kind: part.kind, body: text, untrusted: part.untrusted), db: db)
            }
            return text
        }
    }

    /// AT-250 c2 (M7 bars): replies whose citation checks were still running when the app quit (launch sweep). The
    /// evidence those checks need lived in memory only, so their unverified markers are removed (sentences keep
    /// their words, uncited) and the flag cleared: a pill only stands for a checked passage. Returns the ids changed.
    /// R2 review P2-2: `only` limits it to those replies (a chat's controller that went away mid-check, e.g. its window
    /// closed: the same result as the launch sweep, at once instead of at the next launch).
    @discardableResult
    public func settleUnfinishedCitations(only: Set<String>? = nil, removeMarkers: (String) -> String) throws -> [String] {
        try database.write { db in
            var ids: [String] = []
            for var message in try MessageRecord.filter(sql: "provenance_json LIKE '%citations_checking%'").fetchAll(db)
            where message.provenance?.citationsChecking == true && only.map({ $0.contains(message.id) }) ?? true {
                message.provenance?.citationsChecking = nil
                try message.update(db)
                if var part = try Self.parts(of: message.id, db: db).first(where: { $0.kind == .text }) {
                    let text = removeMarkers(part.body)
                    if text != part.body {
                        part.body = text
                        try Self.upsertPart(message.id, idx: part.idx, PartContent(kind: part.kind, body: text, untrusted: part.untrusted), db: db)
                    }
                }
                ids.append(message.id)
            }
            return ids
        }
    }

    /// Launch recovery (R-208 AC2): any message left `pending`/`streaming` by a crash becomes `interrupted`.
    /// Returns the ids changed.
    @discardableResult
    public func markInterruptedAfterCrash() throws -> [String] {
        try database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM message WHERE status IN ('pending', 'streaming')")
            try db.execute(sql: "UPDATE message SET status = 'interrupted' WHERE status IN ('pending', 'streaming')")
            return ids
        }
    }

    /// Full-text search over text parts (P-shell-05): message ids, best (`bm25`) first.
    public func search(_ query: String, limit: Int = 50) throws -> [(messageID: String, chatID: String)] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.message_id, m.chat_id FROM message_fts
                JOIN message_part p ON p.id = message_fts.rowid
                JOIN message m ON m.id = p.message_id
                WHERE message_fts MATCH ? ORDER BY bm25(message_fts) LIMIT ?
                """, arguments: [pattern, limit]).map { ($0["message_id"], $0["chat_id"]) }
        }
    }
}
