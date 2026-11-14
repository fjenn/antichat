// M7.T14 step 2 (R-266; P-shell-12, deferred from M1.T16 "ToolIndexService/discovery is M7"): "RAG over tools" — the
// tools of a turn ranked against the user's message by a hybrid of lexical BM25 and the shared embedding model
// (G-066, the router's `embed` slot), fused with Reciprocal Rank Fusion.
//
// Ported from osaurus-ai/osaurus@2922745 (MIT):
//   - Packages/OsaurusCore/Services/Tool/ToolSearchService.swift L373-579 (`searchHybridWithDiagnostic`: BM25 +
//     embedding ranks fused with RRF k = 60, items in one source still score, the score-aware embed gate
//     `minEmbedCosine`, the diagnostic hit), L818-840 (`buildIndexText`: name + description + parameter
//     names/descriptions);
//   - Packages/OsaurusCore/Services/Tool/ToolIndexService.swift (sync the registry into the index; stale entries pruned).
// Changes from upstream: the index is in memory over the turn's candidate tools (≤ a few dozen; no ToolDatabase /
// FTS5 / VecturaKit — the GRDB/sqlite-vec store is not needed at this size, P-shell-12 "alternatives rejected"), BM25
// is computed here (k1 1.2, b 0.75) over lower-cased word tokens with tool-name underscores split, the vectors are
// cached per (embed model, index text) and computed in the background (a turn never waits for them, like the
// router's prototypes), the query vector is the one the pre-router already embedded for this message, and instead of
// upstream's fused-score cutoff a hit is *relevant* when its cosine passes the gate (or, with no vectors, when it is a
// lexical hit): ToolSelector offers only relevant similarity hits, `find_tools` reaches the rest.
// Scores only rank and expose tools; nothing here blocks or rewrites a request (R-241).
import Accelerate
import AntiChatEngineProtocol
import Foundation

public actor ToolIndex {
    /// One candidate's ranks and scores (diagnostics, bench and tests).
    public struct Hit: Sendable, Hashable {
        public var name: String
        public var bm25Rank: Int?
        public var bm25Score: Float?
        public var embedRank: Int?
        public var embedScore: Float?
        public var fusedScore: Float
        /// Passed the relevance gate (embed cosine ≥ the floor, or a lexical hit when no vectors exist).
        public var relevant: Bool

        public init(name: String, bm25Rank: Int? = nil, bm25Score: Float? = nil, embedRank: Int? = nil,
                    embedScore: Float? = nil, fusedScore: Float, relevant: Bool) {
            self.name = name; self.bm25Rank = bm25Rank; self.bm25Score = bm25Score; self.embedRank = embedRank
            self.embedScore = embedScore; self.fusedScore = fusedScore; self.relevant = relevant
        }
    }

    /// RRF k (Cormack, Clarke, Buettcher 2009; the upstream constant).
    static let rrfK: Float = 60

    private let embedding: (any RouteEmbedding)?
    private var vectors: [String: [Float]] = [:]
    private var vectorModel: String?
    private var preparing: Task<Void, Never>?

    public init(embedding: (any RouteEmbedding)?) { self.embedding = embedding }

    /// The text a tool is indexed by (upstream `buildIndexText`): name (underscores as spaces) + description +
    /// parameter names and descriptions.
    public static func indexText(_ t: ToolSchema) -> String {
        var parts = [t.name.replacingOccurrences(of: "_", with: " "), t.description]
        if let o = (try? JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))) as? [String: Any],
           let props = o["properties"] as? [String: Any] {
            for k in props.keys.sorted() {
                parts.append(k.replacingOccurrences(of: "_", with: " "))
                if let d = (props[k] as? [String: Any])?["description"] as? String { parts.append(d) }
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Vectors exist for every tool in `tools` (for the current embed model).
    public func isReady(_ tools: [ToolSchema]) -> Bool {
        guard let m = embedding?.modelID, m == vectorModel else { return false }
        return tools.allSatisfy { vectors[Self.indexText($0)] != nil }
    }

    /// Embeds the tools that have no vector yet (idempotent; false without an embed model or on failure).
    @discardableResult
    public func prepare(_ tools: [ToolSchema]) async -> Bool {
        guard let embedding, let model = embedding.modelID else { return false }
        if model != vectorModel { vectors = [:]; vectorModel = model }
        let missing = Array(Set(tools.map(Self.indexText)).subtracting(vectors.keys)).sorted()
        guard !missing.isEmpty else { return true }
        do {
            for start in stride(from: 0, to: missing.count, by: 32) {
                let chunk = Array(missing[start..<min(missing.count, start + 32)])
                let out = try await embedding.embed(chunk)
                guard out.count == chunk.count else { return false }
                for (t, v) in zip(chunk, out) { vectors[t] = Self.unit(v) }
            }
            return true
        } catch {
            return false
        }
    }

    /// Starts `prepare` in the background unless it is running (the turn goes on with what is ready).
    public func prepareInBackground(_ tools: [ToolSchema]) {
        guard embedding?.modelID != nil, preparing == nil, !isReady(tools) else { return }
        preparing = Task { [weak self] in
            _ = await self?.prepare(tools)
            await self?.donePreparing()
        }
    }

    private func donePreparing() { preparing = nil }

    /// Embeds `text` (find_tools, the bench). Symmetric like the router (no query instruction): measured on
    /// tool-select-200, Qwen3-Embedding's instructed query form scored lower at every floor (A-M7-T14a).
    public func queryVector(_ text: String) async -> [Float]? {
        guard let embedding, let v = try? await embedding.embed([text]).first else { return nil }
        return Self.unit(v)
    }

    /// The candidates ranked for `query` (upstream `searchHybridWithDiagnostic`): every tool with a BM25 or a gated
    /// embedding rank, best fused score first, ties by name. `queryVector` nil (or no tool vectors) = lexical only.
    public func search(query: String, queryVector: [Float]?, among tools: [ToolSchema], minEmbedCosine: Float) -> [Hit] {
        let texts = tools.map(Self.indexText)
        let bm25 = Self.bm25(query: query, documents: texts)
        let bm25Ranked = bm25.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.map(\.offset)
        var embedScores: [Int: Float] = [:]
        if let q = queryVector, embedding?.modelID == vectorModel {
            for (i, t) in texts.enumerated() { if let v = vectors[t], v.count == q.count { embedScores[i] = Self.dot(q, v) } }
        }
        let embedRanked = embedScores.sorted { $0.value > $1.value }.map(\.key)
        var bm25Rank: [Int: Int] = [:], embedRank: [Int: Int] = [:]
        for (r, i) in bm25Ranked.enumerated() { bm25Rank[i] = r + 1 }
        for (r, i) in embedRanked.enumerated() { embedRank[i] = r + 1 }
        let semantic = !embedScores.isEmpty
        let k = Self.rrfK
        var hits: [Hit] = []
        for i in tools.indices {
            let gated = (embedScores[i] ?? -1) >= minEmbedCosine
            let s1 = bm25Rank[i].map { 1 / (k + Float($0)) } ?? 0
            let s2 = gated ? (embedRank[i].map { 1 / (k + Float($0)) } ?? 0) : 0
            guard s1 + s2 > 0 else { continue }
            hits.append(Hit(name: tools[i].name, bm25Rank: bm25Rank[i], bm25Score: bm25Rank[i] == nil ? nil : bm25[i],
                            embedRank: embedRank[i], embedScore: embedScores[i], fusedScore: s1 + s2,
                            relevant: semantic ? gated : bm25Rank[i] != nil))
        }
        return hits.sorted { $0.fusedScore != $1.fusedScore ? $0.fusedScore > $1.fusedScore : $0.name < $1.name }
    }

    // MARK: Lexical

    /// Function words that carry no tool meaning (English; other languages rely on the embedding side).
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could", "do", "does", "for", "from", "get", "give",
        "have", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "please", "so",
        "some", "that", "the", "their", "them", "then", "there", "this", "to", "up", "us", "use", "was", "we", "what",
        "when", "where", "which", "who", "why", "will", "with", "would", "you", "your", "tool", "tools", "user", "given",
        "about", "any", "all", "one", "out", "just", "like", "also", "only", "not", "no", "yes", "it's", "i'm",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Okapi BM25 of `query` against each document (k1 1.2, b 0.75; idf with the +1 floor).
    static func bm25(query: String, documents: [String]) -> [Float] {
        let q = Array(Set(tokens(query)))
        let docs = documents.map(tokens)
        guard !q.isEmpty, !docs.isEmpty else { return documents.map { _ in 0 } }
        let n = Float(docs.count)
        let avg = max(1, Float(docs.reduce(0) { $0 + $1.count }) / n)
        var df: [String: Float] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        return docs.map { d in
            var tf: [String: Float] = [:]
            for t in d { tf[t, default: 0] += 1 }
            let len = Float(d.count)
            return q.reduce(Float(0)) { acc, t in
                guard let f = tf[t], let dft = df[t] else { return acc }
                let idf = log(1 + (n - dft + 0.5) / (dft + 0.5))
                return acc + idf * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * len / avg))
            }
        }
    }

    // MARK: Vectors

    static func unit(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let n = sqrt(norm)
        return n > 0 ? v.map { $0 / n } : v
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }
}
