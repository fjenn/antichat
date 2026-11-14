// M2.T16 step 5 (R-244, R-295): FTS5 bm25 top 50 + vec0 KNN top 50 → RRF (k = 60) → optional rerank of the top 20
// (T2+, skipped when the 300 ms budget is already spent) → one hit per chat. Without an embedder, with the model
// missing or not loaded, or with `FeatureFlag.semanticSearch` off, the result is the FTS list alone and no error
// surfaces (R-244 AC3).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB

public struct HybridRetriever: Sendable {
    public struct Hit: Hashable, Sendable {
        public let chatID: String
        public let chunkID: Int64
        public let text: String
        public let score: Double
        /// True when the vector list contributed (the ⌘K semantic section shows only these).
        public let semantic: Bool
    }

    public static let candidates = 50
    public static let rerankTop = 20
    /// R-295: semantic stage budget (p95).
    public static let budget: Duration = .milliseconds(300)

    public let database: AppDatabase
    public let embedder: (any Embedder)?
    public let enabled: Bool

    public init(database: AppDatabase, embedder: (any Embedder)?, enabled: Bool = FeatureFlag.semanticSearch.isEnabled()) {
        self.database = database
        self.embedder = embedder
        self.enabled = enabled
    }

    public func search(_ q: String, limit: Int = 10) async -> [Hit] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let start = ContinuousClock.now
        let fts = (try? ftsIDs(query)) ?? []
        var knn: [Int64] = []
        if enabled, let embedder, let v = try? await embedder.embed([query], kind: .query).first, v.count == VecLoader.dimensions {
            knn = (try? knnIDs(v)) ?? []
        }
        var order = RRF.fuse([fts, knn]).map(\.key)
        let semanticSet = Set(knn)
        var texts = (try? texts(Array(order.prefix(max(limit * 3, Self.rerankTop))))) ?? [:]
        if !knn.isEmpty, let embedder, ContinuousClock.now - start < Self.budget {
            let top = Array(order.prefix(Self.rerankTop))
            if let scores = try? await embedder.rerank(query: query, documents: top.map { texts[$0]?.text ?? "" }),
               scores.count == top.count, ContinuousClock.now - start < Self.budget {
                let reranked = zip(top, scores).sorted { $0.1 > $1.1 }.map(\.0)
                order = reranked + order.dropFirst(top.count)
            }
        }
        if texts.count < order.count { texts.merge((try? self.texts(order)) ?? [:]) { a, _ in a } }
        var seen = Set<String>()
        var out: [Hit] = []
        for (rank, id) in order.enumerated() {
            guard let t = texts[id], seen.insert(t.chatID).inserted else { continue }
            out.append(Hit(chatID: t.chatID, chunkID: id, text: t.text, score: 1 / Double(rank + 1),
                           semantic: semanticSet.contains(id)))
            if out.count == limit { break }
        }
        return out
    }

    func ftsIDs(_ q: String) throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: q) else { return [] }
        return try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunk_fts WHERE chunk_fts MATCH ? ORDER BY bm25(chunk_fts) LIMIT ?
                """, arguments: [pattern, Self.candidates])
        }
    }

    func knnIDs(_ v: [Float]) throws -> [Int64] {
        try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunk_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [ChunkTables.blob(v), Self.candidates])
        }
    }

    func texts(_ ids: [Int64]) throws -> [Int64: (chatID: String, text: String)] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            var out: [Int64: (chatID: String, text: String)] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.chat_id, c.text FROM chunk c JOIN chat ON chat.id = c.chat_id
                WHERE c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
            for r in rows { out[r["id"]] = (r["chat_id"], r["text"]) }
            return out
        }
    }
}
