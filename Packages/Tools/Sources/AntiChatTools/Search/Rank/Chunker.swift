// M7.T02 steps 6–7 (R-249; blueprint B §B1.2 step 7): page text → ≈ 350-token chunks (50 overlap, prefixed
// `title — site`) → hybrid rank (BM25 from a temporary in-memory SQLite FTS5 table + cosine on the shared embedding
// model, fused with RRF k = 60; the T2+ reranker per tier-budgets reorders the top 30) → MMR-style source spread
// (≥ 2 sources when there are ≥ 2, at most 2 chunks per domain) → `EvidenceBudget.fit` to the tier's evidence
// token budget, counted with the active model's tokenizer. Every chunk keeps its source index `[n]`.
import Foundation
import GRDB

public struct EvidenceChunk: Sendable, Equatable {
    /// 1-based source index (the `[n]` the model cites).
    public var source: Int
    public var url: URL
    public var site: String
    public var title: String
    public var text: String
    public var ordinal: Int
    public init(source: Int, url: URL, site: String, title: String, text: String, ordinal: Int) {
        self.source = source; self.url = url; self.site = site; self.title = title; self.text = text; self.ordinal = ordinal
    }
}

public enum Chunker {
    /// Word-based token estimate (≈ 0.75 words per token) used only for sizing chunks; the budget uses the tokenizer.
    public static func approxTokens(_ s: String) -> Int { Int((Double(s.split(whereSeparator: \.isWhitespace).count) / 0.75).rounded(.up)) }

    public static func chunks(_ page: ExtractedPage, source: Int, size: Int = 350, overlap: Int = 50) -> [EvidenceChunk] {
        let words = page.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let per = max(1, Int(Double(size) * 0.75)), step = max(1, per - Int(Double(overlap) * 0.75))
        var out: [EvidenceChunk] = [], start = 0, n = 0
        let prefix = page.site.isEmpty ? page.title : "\(page.title) — \(page.site)"
        while start < words.count {
            let body = words[start..<min(words.count, start + per)].joined(separator: " ")
            out.append(EvidenceChunk(source: source, url: page.url, site: page.site, title: page.title, text: "\(prefix)\n\(body)", ordinal: n))
            n += 1
            if start + per >= words.count { break }
            start += step
        }
        return out
    }
}
