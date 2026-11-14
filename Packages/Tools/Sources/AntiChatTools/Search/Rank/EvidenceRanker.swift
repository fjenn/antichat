// M7.T02 step 6: hybrid BM25 (in-memory FTS5) + embeddings (RRF k = 60), T2+ reranker, source spread.
import Foundation
import GRDB

public struct EvidenceRanker: Sendable {
    /// Embeds texts with the shared embedding model (EmbedRequest over XPC, injected by Harness); nil = BM25 only.
    public typealias Embed = @Sendable ([String]) async -> [[Float]]?
    /// Cross-encoder scores for (query, passage) pairs (T2+ reranker); nil = no rerank.
    public typealias Rerank = @Sendable (String, [String]) async -> [Double]?

    public let embed: Embed?
    public let rerank: Rerank?
    public init(embed: Embed? = nil, rerank: Rerank? = nil) { self.embed = embed; self.rerank = rerank }

    /// M9.T05 (AT-254 T3): at most this many chunks are embedded — the BM25 best plus each source's first two chunks
    /// (its lead, which BM25 can miss). Six long reference pages gave 200+ chunks and ≈ 1 s of embedding before the
    /// first token; the rest keep their BM25 place in the fusion (ranked after every embedded chunk's fused score).
    public static let embedCap = 64

    public func rank(query: String, chunks: [EvidenceChunk], useReranker: Bool, perDomain: Int = 2) async -> [EvidenceChunk] {
        guard !chunks.isEmpty else { return [] }
        let bm = (try? Self.bm25(query: query, texts: chunks.map(\.text))) ?? []
        var lists: [[Int]] = [bm]
        if let embed {
            var pick: [Int] = [], seen = Set<Int>(), leads: [Int: Int] = [:]
            for (i, c) in chunks.enumerated() where leads[c.source, default: 0] < 2 {
                leads[c.source, default: 0] += 1
                if seen.insert(i).inserted { pick.append(i) }
            }
            for i in bm where pick.count < Self.embedCap && seen.insert(i).inserted { pick.append(i) }
            if let vecs = await embed([query] + pick.map { chunks[$0].text }), vecs.count == pick.count + 1 {
                let q = vecs[0]
                let cos = zip(pick, vecs.dropFirst()).map { ($0, Self.cosine(q, $1)) }
                lists.append(cos.sorted { $0.1 > $1.1 }.map(\.0))
            }
        }
        var order = Self.rrf(lists, count: chunks.count)
        if useReranker, let rerank {
            let top = Array(order.prefix(30))
            if let s = await rerank(query, top.map { chunks[$0].text }), s.count == top.count {
                order = zip(top, s).sorted { $0.1 > $1.1 }.map(\.0) + order.dropFirst(30)
            }
        }
        return Self.spread(order.map { chunks[$0] }, perDomain: perDomain)
    }

    /// BM25 order of `texts` for `query` via a temporary in-memory FTS5 table (SQLite `bm25()`, lower = better).
    static func bm25(query: String, texts: [String]) throws -> [Int] {
        let db = try DatabaseQueue()
        return try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE c USING fts5(body, tokenize = 'unicode61 remove_diacritics 2')")
            for (i, t) in texts.enumerated() { try db.execute(sql: "INSERT INTO c(rowid, body) VALUES (?, ?)", arguments: [i, t]) }
            let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map { "\"\($0)\"" }
            guard !terms.isEmpty else { return Array(texts.indices) }
            let hits = try Int.fetchAll(db, sql: "SELECT rowid FROM c WHERE c MATCH ? ORDER BY bm25(c)",
                                        arguments: [terms.joined(separator: " OR ")])
            return hits + texts.indices.filter { !hits.contains($0) }
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(d / (na.squareRoot() * nb.squareRoot())) : 0
    }

    /// Reciprocal rank fusion, k = 60 (M2 HybridRetriever's constant).
    static func rrf(_ lists: [[Int]], count: Int, k: Double = 60) -> [Int] {
        var score = [Double](repeating: 0, count: count)
        for l in lists { for (r, i) in l.enumerated() where i < count { score[i] += 1 / (k + Double(r + 1)) } }
        return score.indices.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : $0 < $1 }
    }

    /// Source spread: the best chunk of a second source moves up to position 2 (MMR keeps ≥ 2 sources), and a
    /// domain contributes at most `perDomain` chunks (the rest go to the end, used only if the budget allows).
    static func spread(_ ranked: [EvidenceChunk], perDomain: Int) -> [EvidenceChunk] {
        var out: [EvidenceChunk] = [], overflow: [EvidenceChunk] = [], perSite: [String: Int] = [:]
        for c in ranked {
            let key = c.url.host() ?? c.site
            if perSite[key, default: 0] < perDomain { out.append(c); perSite[key, default: 0] += 1 } else { overflow.append(c) }
        }
        if out.count >= 2, out[0].source == out[1].source, let j = out.firstIndex(where: { $0.source != out[0].source }) {
            out.insert(out.remove(at: j), at: 1)
        }
        return out + overflow
    }
}
