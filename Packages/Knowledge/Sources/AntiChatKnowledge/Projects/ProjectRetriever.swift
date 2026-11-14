// M8.T05 step 2 (R-245 AC2): per-turn hybrid retrieval over a project's file chunks (`chunk.source = 'project_file'`,
// page_ref from intake): FTS5 bm25 top 40 + vec0 KNN top 40 → RRF (k = 60) → rerank of the top 20 with `rerank` on
// T2+ (skipped on T0–T1) → the top 8 within 25 % of the context. Same shape as HybridRetriever (M2.T16) and
// DocumentIndexer.retrieve (M6.T02), scoped to one project. No network (local index only).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

public struct ProjectSourceHit: Sendable, Equatable {
    public var chunkID: Int64
    public var fileID: String
    public var fileName: String
    /// The chunk's page ref (PDF physical page index, `Slide n`, sheet / section label); nil = none.
    public var page: String?
    public var text: String
    public var semantic: Bool

    public init(chunkID: Int64, fileID: String, fileName: String, page: String?, text: String, semantic: Bool) {
        self.chunkID = chunkID; self.fileID = fileID; self.fileName = fileName; self.page = page; self.text = text
        self.semantic = semantic
    }
}

public struct ProjectRetriever: Sendable {
    public static let candidates = 40
    public static let rerankTop = 20
    public static let topK = 8
    /// The excerpts' share of the model context.
    public static let contextShare = 0.25
    public static let rerankTiers: Set<String> = ["T2", "T3", "T4"]

    public let database: AppDatabase
    public let embedder: (any Embedder)?

    public init(database: AppDatabase, embedder: (any Embedder)?) {
        self.database = database
        self.embedder = embedder
    }

    /// The search text: the newest user message plus the one before it (follow-ups like "and in March?").
    public static func query(lastUser: String, previousUser: String?) -> String {
        [previousUser, lastUser].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public func search(_ query: String, projectID: String, tier: String, contextLength: Int, k: Int = ProjectRetriever.topK,
                       countTokens: (String) -> Int = { max(1, $0.utf8.count / 4) }) async -> [ProjectSourceHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let (anchored, fts) = (try? ftsLists(q, projectID: projectID)) ?? ([], [])
        var knn: [Int64] = []
        if let embedder, !database.isInMemory, let v = try? await embedder.embed([q], kind: .query).first,
           v.count == VecLoader.dimensions {
            knn = (try? knnIDs(v, projectID: projectID)) ?? []
        }
        // The anchored list counts twice: a passage naming the question's site / code beats one that only shares its
        // wording (AT-245 run 2 → run 3).
        var order = RRF.fuse([anchored, anchored, fts, knn]).map(\.key)
        let semantic = Set(knn)
        var rows = (try? self.rows(Array(order.prefix(max(Self.candidates, k * 3))))) ?? [:]
        var reranked = false
        if Self.rerankTiers.contains(Self.tierClass(tier)), let embedder, order.count > 1 {
            let top = Array(order.prefix(Self.rerankTop))
            if let scores = try? await embedder.rerank(query: q, documents: top.map { rows[$0]?.text ?? "" }), scores.count == top.count {
                order = zip(top, scores).sorted { $0.1 > $1.1 }.map(\.0) + order.dropFirst(top.count)
                reranked = true
            }
        }
        if !reranked {  // T0–T1 (no reranker model): the sentence-level lexical rerank below
            let anchors = Self.anchors(q)
            let top = Array(order.prefix(Self.candidates))
            let scores = top.map { Self.sentenceScore(rows[$0]?.text ?? "", query: q, anchors: anchors) }
            order = top.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }.map { top[$0] }
                + order.dropFirst(top.count)
        }
        if rows.count < min(order.count, k * 3) { rows.merge((try? self.rows(Array(order.prefix(k * 3)))) ?? [:]) { a, _ in a } }
        let cap = Int(Double(contextLength) * Self.contextShare)
        var used = 0
        var out: [ProjectSourceHit] = []
        for id in order {
            guard var h = rows[id] else { continue }
            let t = countTokens(h.text)
            if used + t > cap { if out.isEmpty { continue } else { break } }
            used += t
            h.semantic = semantic.contains(id)
            out.append(h)
            if out.count == k { break }
        }
        return out
    }

    static let stopwords: Set<String> = ["the", "and", "for", "what", "which", "who", "whom", "how", "many", "much", "does",
                                          "did", "was", "were", "are", "is", "its", "his", "her", "their", "this", "that",
                                          "with", "from", "into", "about", "has", "have", "had", "when", "where", "there"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init)
    }

    /// The best sentence of `text` for the question: 3 per anchor it names + 1 per other content word it shares. A
    /// cheap stand-in for the reranker on T0–T1: in a project of look-alike documents the right passage is the one
    /// whose *sentence* names the question's site or code next to its wording, not the one that has both somewhere.
    static func sentenceScore(_ text: String, query: String, anchors: [String]) -> Int {
        let a = Set(anchors.map { $0.lowercased() })
        let terms = Set(words(query).filter { $0.count >= 3 && !stopwords.contains($0) }).subtracting(a)
        var best = 0
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            let w = Set(words(String(sentence)))
            let anchorHits = a.filter { anchor in anchor.contains("-") ? sentence.lowercased().contains(anchor) : w.contains(anchor) }.count
            best = max(best, 3 * anchorHits + terms.intersection(w).count)
        }
        return best
    }

    /// `T2-24` → `T2`.
    static func tierClass(_ tier: String) -> String { String(tier.prefix(2)) }

    /// FTS candidates: the any-token bm25 list, preceded by the same list restricted to chunks that contain every
    /// "anchor" of the question (names and codes: capitalised words after the first, tokens with digits). A project
    /// of similar documents (site reports, registers) repeats the question's wording everywhere; the anchor is what
    /// tells the right passage apart (AT-245: 25/50 → see build/at/AT-245).
    func ftsIDs(_ q: String, projectID: String) throws -> [Int64] {
        let (a, p) = try ftsLists(q, projectID: projectID)
        var seen = Set<Int64>()
        return (a + p).filter { seen.insert($0).inserted }
    }

    /// (anchored, any-token) bm25 lists.
    func ftsLists(_ q: String, projectID: String) throws -> ([Int64], [Int64]) {
        guard let any = FTS5Pattern(matchingAnyTokenIn: q) else { return ([], []) }
        let anchors = Self.anchors(q)
        return try database.read { db in
            func fetch(_ pattern: FTS5Pattern) throws -> [Int64] {
                try Int64.fetchAll(db, sql: """
                    SELECT f.rowid FROM chunk_fts f JOIN chunk c ON c.id = f.rowid JOIN project_file pf ON pf.id = c.source_id
                    WHERE chunk_fts MATCH ? AND c.source = ? AND pf.project_id = ? ORDER BY bm25(chunk_fts) LIMIT ?
                    """, arguments: [pattern, ProjectFile.chunkSource, projectID, Self.candidates])
            }
            var anchored: [Int64] = []
            if !anchors.isEmpty, let raw = try? FTS5Pattern(rawPattern: anchors.map { "\"\($0)\"" }.joined(separator: " AND ")
                                                                  + " AND (\(any.rawPattern))") {
                anchored = (try? fetch(raw)) ?? []
            }
            return (anchored, try fetch(any))
        }
    }

    /// Names and codes in the question: capitalised words that do not start a sentence, and tokens with a digit.
    static func anchors(_ q: String) -> [String] {
        var out: [String] = []
        var sentenceStart = true
        for raw in q.split(whereSeparator: { $0.isWhitespace }) {
            let w = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
                .replacingOccurrences(of: "\"", with: "")
            defer { sentenceStart = raw.last.map { ".?!:".contains($0) } ?? false }
            guard w.count >= 2 else { continue }
            let hasDigit = w.contains(where: \.isNumber)
            let capital = w.first?.isUppercase == true && !sentenceStart
            if hasDigit || capital, !out.contains(w) { out.append(w) }
        }
        return out
    }

    func knnIDs(_ v: [Float], projectID: String) throws -> [Int64] {
        try database.read { db in
            // vec0 KNN has no join filter: over-fetch, then keep this project's chunks (DocumentIndexer pattern).
            let ids = try Int64.fetchAll(db, sql: "SELECT rowid FROM chunk_vec WHERE embedding MATCH ? AND k = 1000 ORDER BY distance",
                                         arguments: [ChunkTables.blob(v)])
            guard !ids.isEmpty else { return [] }
            let mine = Set(try Int64.fetchAll(db, sql: """
                SELECT c.id FROM chunk c JOIN project_file pf ON pf.id = c.source_id
                WHERE c.source = ? AND pf.project_id = ? AND c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([ProjectFile.chunkSource, projectID] as [any DatabaseValueConvertible] + ids)))
            return Array(ids.filter(mine.contains).prefix(Self.candidates))
        }
    }

    func rows(_ ids: [Int64]) throws -> [Int64: ProjectSourceHit] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            var out: [Int64: ProjectSourceHit] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT c.id, c.text, c.page_ref, pf.id AS fid, pf.display_name FROM chunk c JOIN project_file pf ON pf.id = c.source_id
                WHERE c.source = ? AND c.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([ProjectFile.chunkSource] as [any DatabaseValueConvertible] + ids)) {
                out[r["id"]] = ProjectSourceHit(chunkID: r["id"], fileID: r["fid"], fileName: r["display_name"],
                                                page: r["page_ref"], text: r["text"], semantic: false)
            }
            return out
        }
    }
}
