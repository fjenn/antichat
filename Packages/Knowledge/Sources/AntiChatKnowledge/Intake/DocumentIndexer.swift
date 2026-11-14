// M6.T02 step 3 (R-270 excerpt path): a document's structure-aware chunks with their page reference, and retrieval
// over them. Chunks follow the unit map (pages / sheets / slides / sections; never across a unit), ≈ 400 tokens
// (1,600 characters) with ≈ 60 tokens (240 characters) of overlap, cut on line boundaries so a table row is never
// split. Each chunk is a `chunk` row (`source = 'document'`, `source_id` = the blob's sha256, so the same file attached
// twice is indexed once; no chat_id: it stays out of chat search) with `page_ref` = the PDF page number, `Slide n`,
// `<sheet name>` or the section title. Retrieval = BM25 (chunk_fts) + vector kNN (chunk_vec, when an embedder is
// present) fused with RRF (P-media-15 HybridRetriever's method), restricted to the document; top-k per tier comes
// from tier-budgets.json. Without an embedder (or for incognito) it is keyword-only and says so (`semantic = false`).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

public struct DocumentChunk: Sendable, Equatable {
    public var id: Int64
    public var ord: Int
    public var text: String
    public var pageRef: String?
}

public struct DocumentIndexer: Sendable {
    public static let source = "document"
    public static let chunkChars = 1_600
    public static let overlapChars = 240

    public let database: AppDatabase
    public let embedder: (any Embedder)?

    public init(database: AppDatabase, embedder: (any Embedder)?) {
        self.database = database
        self.embedder = embedder
    }

    /// The unit's page reference.
    public static func pageRef(_ u: ExtractedDocument.Unit) -> String {
        switch u.kind {
        case .page: "\(u.index)"
        case .slide: "Slide \(u.index)"
        case .sheet: u.label ?? "Sheet \(u.index)"
        case .section: u.label ?? "Section \(u.index)"
        }
    }

    /// Pieces of one unit's text: line-aligned windows of ≤ `chunkChars` with `overlapChars` carried over.
    public static func pieces(_ text: String, max: Int = chunkChars, overlap: Int = overlapChars) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var cur: [String] = []
        var len = 0
        func flush() {
            let piece = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            // Overlap: keep trailing lines worth ≤ overlap characters.
            var keep: [String] = []
            var k = 0
            for l in cur.reversed() {
                if k + l.count > overlap { break }
                keep.insert(l, at: 0)
                k += l.count + 1
            }
            cur = keep
            len = k
        }
        for line in lines {
            // A single over-long line (prose without breaks) is cut on sentence/word boundaries.
            for part in split(line, max: max) {
                if len + part.count + 1 > max, !cur.isEmpty { flush() }
                cur.append(part)
                len += part.count + 1
            }
        }
        if cur.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let piece = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty, out.last.map({ !$0.hasSuffix(piece) }) ?? true { out.append(piece) }
        }
        return out
    }

    static func split(_ line: String, max: Int) -> [String] {
        guard line.count > max else { return [line] }
        var out: [String] = []
        var cur = ""
        for sentence in line.split(separator: " ", omittingEmptySubsequences: false) {
            if cur.count + sentence.count + 1 > max / 2, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            cur += cur.isEmpty ? String(sentence) : " " + sentence
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Chunks `doc` for blob `sha256` (no-op when already indexed). Returns the chunk count.
    /// M6.T04: a PDF is indexed per page — a page still waiting for OCR (text below the scan threshold) is skipped and
    /// joins the index once its text is there; chunks of earlier pages (and the `retrieval` rows of earlier turns that
    /// point at them) are never rewritten.
    @discardableResult
    public func index(sha256: String, doc: ExtractedDocument, now: Date = Date()) throws -> Int {
        try database.write { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk WHERE source = ? AND source_id = ?",
                                     arguments: [Self.source, sha256]) ?? 0
            let paged = doc.units.contains { $0.kind == .page }
            if n > 0, !paged { return n }
            let have = Set(try String.fetchAll(db, sql: "SELECT DISTINCT page_ref FROM chunk WHERE source = ? AND source_id = ?",
                                               arguments: [Self.source, sha256]))
            var ord = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ord) + 1, 0) FROM chunk WHERE source = ? AND source_id = ?",
                                       arguments: [Self.source, sha256]) ?? 0
            let units = doc.units.isEmpty
                ? [ExtractedDocument.Unit(kind: .section, index: 1, start: 0, end: doc.markdown.utf16.count)] : doc.units
            for u in units {
                if paged, have.contains(Self.pageRef(u)) { continue }
                if paged, u.kind == .page, ScanDetector.needsOCR(doc.text(of: u)) { continue }
                for piece in Self.pieces(doc.text(of: u)) {
                    try db.execute(sql: """
                        INSERT INTO chunk(source, source_id, chat_id, ord, text, created_at, page_ref) VALUES (?, ?, NULL, ?, ?, ?, ?)
                        """, arguments: [Self.source, sha256, ord, piece, now.timeIntervalSince1970, Self.pageRef(u)])
                    ord += 1
                }
            }
            return ord
        }
    }

    /// Embeds the document's chunks that have no vector yet (best effort; false = keyword-only).
    @discardableResult
    public func embed(sha256: String, batch: Int = 32) async -> Bool {
        guard let embedder, !database.isInMemory else { return false }
        do {
            while true {
                let rows = try database.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT c.id, c.text FROM chunk c WHERE c.source = ? AND c.source_id = ?
                          AND NOT EXISTS (SELECT 1 FROM chunk_vec v WHERE v.rowid = c.id) ORDER BY c.ord LIMIT ?
                        """, arguments: [Self.source, sha256, batch])
                }
                if rows.isEmpty { return true }
                let vectors = try await embedder.embed(rows.map { $0["text"] }, kind: .document)
                guard vectors.count == rows.count else { return false }
                try database.write { db in
                    for (r, v) in zip(rows, vectors) where v.count == VecLoader.dimensions {
                        try db.execute(sql: "INSERT OR REPLACE INTO chunk_vec(rowid, embedding) VALUES (?, ?)",
                                       arguments: [r["id"] as Int64, ChunkTables.blob(v)])
                    }
                }
            }
        } catch {
            return false
        }
    }

    public struct Result: Sendable {
        public var chunks: [DocumentChunk]
        /// Vector search took part (else keyword only).
        public var semantic: Bool
    }

    /// Top-`k` chunks of the document for `query` (RRF over BM25 and kNN), in rank order.
    public func retrieve(_ query: String, sha256: String, k: Int) async -> Result {
        let fts = (try? ftsIDs(query, sha256: sha256)) ?? []
        var knn: [Int64] = []
        if let embedder, !database.isInMemory, let v = try? await embedder.embed([query], kind: .query).first,
           v.count == VecLoader.dimensions {
            knn = (try? knnIDs(v, sha256: sha256)) ?? []
        }
        var order = RRF.fuse([fts, knn]).map(\.key)
        if order.isEmpty {  // no keyword overlap and no vectors: the document's first chunks
            order = (try? database.read { db in
                try Int64.fetchAll(db, sql: "SELECT id FROM chunk WHERE source = ? AND source_id = ? ORDER BY ord LIMIT ?",
                                   arguments: [Self.source, sha256, k])
            }) ?? []
        }
        let top = Array(order.prefix(k))
        let byID = (try? chunks(top)) ?? [:]
        return Result(chunks: top.compactMap { byID[$0] }, semantic: !knn.isEmpty)
    }

    func ftsIDs(_ q: String, sha256: String) throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: q) else { return [] }
        return try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT f.rowid FROM chunk_fts f JOIN chunk c ON c.id = f.rowid
                WHERE chunk_fts MATCH ? AND c.source = ? AND c.source_id = ? ORDER BY bm25(chunk_fts) LIMIT 50
                """, arguments: [pattern, Self.source, sha256])
        }
    }

    func knnIDs(_ v: [Float], sha256: String) throws -> [Int64] {
        try database.read { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunk_vec WHERE embedding MATCH ? AND k = 400 ORDER BY distance
                """, arguments: [ChunkTables.blob(v)])
            guard !ids.isEmpty else { return [] }
            let mine = Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM chunk WHERE source = ? AND source_id = ? AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([Self.source, sha256] as [any DatabaseValueConvertible] + ids)))
            return Array(ids.filter(mine.contains).prefix(50))
        }
    }

    public func chunks(_ ids: [Int64]) throws -> [Int64: DocumentChunk] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            var out: [Int64: DocumentChunk] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT id, ord, text, page_ref FROM chunk WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids)) {
                out[r["id"]] = DocumentChunk(id: r["id"], ord: r["ord"], text: r["text"], pageRef: r["page_ref"])
            }
            return out
        }
    }
}
