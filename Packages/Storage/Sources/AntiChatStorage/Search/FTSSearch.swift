// ⌘K full-text search (M1.T11 step 3, R-012, P-shell-05): chat titles (`chat_fts`) ∪ text-part bodies
// (`message_fts`), ranked by `bm25()`, one row per chat with a `snippet()` of its best-matching message. Raw SQL:
// GRDB has no query-interface spelling for `bm25`/`snippet` (GRDB FTS5 docs). Every local chat is searched,
// archived ones included (R-012 AC1 "all local chats"); the incognito store is a different database.
//
// Ranking: chats whose title matches come first (title bm25 order), then chats that match only in a body (body
// bm25 order). A single-character query ranks bodies by recency instead of bm25: ranking the ~50k rows a one-letter
// prefix matches costs ~100 ms on the 10k-chat fixture, the recency scan ~10 ms (M1.T11 failure mode 1).
import Foundation
import GRDB

public struct FTSSearch: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// Marks around a match inside `Snippet.text` (`snippet()` open/close arguments). Control characters never
    /// typed in a chat; `Snippet.runs` splits on them.
    static let open = "\u{2}", close = "\u{3}"
    /// Tokens of context `snippet()` keeps around the match.
    static let snippetTokens = 12
    /// Body rows ranked before the per-chat de-duplication (a chat can own several of the best rows).
    static let bodyRowFactor = 3

    /// One matched message excerpt with its highlighted spans.
    public struct Snippet: Hashable, Sendable {
        /// The excerpt with `FTSSearch.open` / `.close` around each match.
        public let marked: String

        /// `(text, isMatch)` runs in order (empty runs dropped).
        public var runs: [(text: String, isMatch: Bool)] {
            var out: [(String, Bool)] = []
            var match = false
            var current = ""
            for ch in marked {
                let s = String(ch)
                if s == FTSSearch.open || s == FTSSearch.close {
                    if !current.isEmpty { out.append((current, match)) }
                    current = ""
                    match = s == FTSSearch.open
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { out.append((current, match)) }
            return out.map { (text: $0.0, isMatch: $0.1) }
        }

        /// The excerpt without marks.
        public var plain: String { runs.map(\.text).joined() }
    }

    /// One chat in the results.
    public struct Hit: Hashable, Sendable {
        public let chatID: String
        public let title: String
        public let isEvil: Bool
        public let archived: Bool
        public let updatedAt: Date
        /// The title matched the query.
        public let titleMatched: Bool
        /// The best-ranked matching message of the chat (nil for a title-only match).
        public let messageID: String?
        public let snippet: Snippet?
    }

    // MARK: Search

    /// Chats matching every word of `query` as a prefix (`FTS5Pattern(matchingAllPrefixesIn:)`), at most `limit`.
    /// `likedOnly` keeps body matches in messages rated 👍 (`feedback.kind = 'liked'`) and drops title-only matches.
    public func search(_ query: String, limit: Int = 30, likedOnly: Bool = false) throws -> [Hit] {
        guard limit > 0, let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let byRecency = query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
        return try database.read { db in
            var hits: [Hit] = []
            var seen = Set<String>()
            let bodies = try bodyRows(db, pattern: pattern, limit: limit * Self.bodyRowFactor, likedOnly: likedOnly,
                                      byRecency: byRecency)
            var bestBody: [String: (messageID: String, snippet: Snippet)] = [:]
            for row in bodies where bestBody[row.chatID] == nil {
                bestBody[row.chatID] = (row.messageID, row.snippet)
            }
            if !likedOnly {
                for row in try titleRows(db, pattern: pattern, limit: limit) where seen.insert(row.id).inserted {
                    let body = bestBody[row.id]
                    hits.append(Hit(chatID: row.id, title: row.title, isEvil: row.isEvil, archived: row.archived,
                                    updatedAt: row.updatedAt, titleMatched: true, messageID: body?.messageID,
                                    snippet: body?.snippet))
                    if hits.count == limit { return hits }
                }
            }
            for row in bodies where seen.insert(row.chatID).inserted {
                hits.append(Hit(chatID: row.chatID, title: row.title, isEvil: row.isEvil, archived: row.archived,
                                updatedAt: row.updatedAt, titleMatched: false, messageID: row.messageID,
                                snippet: row.snippet))
                if hits.count == limit { break }
            }
            return hits
        }
    }

    /// The empty-query list: most recently updated non-archived chats, or (`likedOnly`) the chats of the most
    /// recently liked replies, each with an excerpt of that reply.
    public func recents(limit: Int = 8, likedOnly: Bool = false) throws -> [Hit] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            if likedOnly {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.id, c.title, c.mode, c.archived_at, c.updated_at, m.id AS message_id,
                           substr(p.body, 1, 160) AS excerpt
                    FROM feedback f
                    JOIN message m ON m.id = f.message_id
                    JOIN chat c ON c.id = m.chat_id
                    JOIN message_part p ON p.message_id = m.id AND p.kind = 'text'
                    WHERE f.kind = 'liked'
                    ORDER BY f.created_at DESC, p.idx
                    """)
                var seen = Set<String>()
                var hits: [Hit] = []
                for r in rows where seen.insert(r["id"]).inserted {
                    let excerpt: String = r["excerpt"]
                    hits.append(Hit(chatID: r["id"], title: r["title"], isEvil: (r["mode"] as String) == "evil",
                                    archived: (r["archived_at"] as Double?) != nil, updatedAt: Self.date(r["updated_at"]),
                                    titleMatched: false, messageID: r["message_id"],
                                    snippet: Snippet(marked: Self.clean(excerpt))))
                    if hits.count == limit { break }
                }
                return hits
            }
            return try Row.fetchAll(db, sql: """
                SELECT id, title, mode, archived_at, updated_at FROM chat
                WHERE archived_at IS NULL ORDER BY updated_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map { r in
                Hit(chatID: r["id"], title: r["title"], isEvil: (r["mode"] as String) == "evil", archived: false,
                    updatedAt: Self.date(r["updated_at"]), titleMatched: false, messageID: nil, snippet: nil)
            }
        }
    }

    // MARK: Queries

    private struct TitleRow { let id, title: String; let isEvil, archived: Bool; let updatedAt: Date }
    private struct BodyRow {
        let chatID, title, messageID: String
        let isEvil, archived: Bool
        let updatedAt: Date
        let snippet: Snippet
    }

    private func titleRows(_ db: Database, pattern: FTS5Pattern, limit: Int) throws -> [TitleRow] {
        try Row.fetchAll(db, sql: """
            SELECT c.id, c.title, c.mode, c.archived_at, c.updated_at FROM chat_fts
            JOIN chat c ON c.rowid = chat_fts.rowid
            WHERE chat_fts MATCH ? ORDER BY bm25(chat_fts), c.updated_at DESC LIMIT ?
            """, arguments: [pattern, limit]).map { r in
            TitleRow(id: r["id"], title: r["title"], isEvil: (r["mode"] as String) == "evil",
                     archived: (r["archived_at"] as Double?) != nil, updatedAt: Self.date(r["updated_at"]))
        }
    }

    /// The best `limit` text parts: ranked in FTS5 first (`ORDER BY rank LIMIT`, snippets only for those rows),
    /// then joined to their message and chat.
    private func bodyRows(_ db: Database, pattern: FTS5Pattern, limit: Int, likedOnly: Bool,
                          byRecency: Bool) throws -> [BodyRow] {
        let liked = likedOnly ? """
            AND rowid IN (SELECT p.id FROM feedback f JOIN message_part p ON p.message_id = f.message_id
                          WHERE f.kind = 'liked' AND p.kind = 'text')
            """ : ""
        // `rank` is bm25 (lower = better); recency = newest part first (AUTOINCREMENT ids grow with time).
        let ord = byRecency ? "-rowid" : "rank"
        // M1.T18: compaction summaries (`system_note` rows) are never hits; the originals they summarise are.
        let sql = """
            SELECT p.message_id, c.id AS chat_id, c.title, c.mode, c.archived_at, c.updated_at, hit.snip
            FROM (SELECT rowid AS part_id, snippet(message_fts, 0, ?, ?, '…', ?) AS snip, \(ord) AS ord
                  FROM message_fts WHERE message_fts MATCH ? \(liked)
                  ORDER BY \(byRecency ? "rowid DESC" : "rank") LIMIT ?) AS hit
            JOIN message_part p ON p.id = hit.part_id
            JOIN message m ON m.id = p.message_id
            JOIN chat c ON c.id = m.chat_id
            WHERE m.role != 'system_note'
            ORDER BY hit.ord
            """
        return try Row.fetchAll(db, sql: sql, arguments: [Self.open, Self.close, Self.snippetTokens, pattern, limit])
            .map { r in
                BodyRow(chatID: r["chat_id"], title: r["title"], messageID: r["message_id"],
                        isEvil: (r["mode"] as String) == "evil", archived: (r["archived_at"] as Double?) != nil,
                        updatedAt: Self.date(r["updated_at"]), snippet: Snippet(marked: r["snip"]))
            }
    }

    // MARK: Helpers

    static func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    /// Removes stray mark characters from text that did not come out of `snippet()` (liked excerpts).
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
