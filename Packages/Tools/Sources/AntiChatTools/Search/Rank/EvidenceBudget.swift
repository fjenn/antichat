// M7.T02 step 7: the evidence block fits the tier's evidence token budget (active model's tokenizer).
import Foundation

public enum EvidenceBudget {
    /// Tokens of a text with the active model's tokenizer (engine `CountTokens`), injected by Harness.
    public typealias Count = @Sendable (String) async -> Int
    /// M9.T05 (AT-254): the same, for many texts in one request (the helper's tokenizer, one XPC round trip).
    public typealias BatchCount = @Sendable ([String]) async -> [Int]

    /// The rendered chunk as it enters the `<web_results>` block (its tokens are what the budget counts).
    public static func render(_ c: EvidenceChunk) -> String { "[\(c.source)] \(c.text)" }

    /// Keeps chunks in rank order while the running total stays ≤ `budget` tokens; a chunk that does not fit is
    /// skipped (a smaller later one may still fit). Never exceeds the budget.
    public static func fit(_ ranked: [EvidenceChunk], budget: Int, count: Count) async -> (chunks: [EvidenceChunk], tokens: Int) {
        var used = 0, out: [EvidenceChunk] = []
        for c in ranked {
            let t = await count(render(c)) + 1  // + the separating newline
            if used + t <= budget { out.append(c); used += t }
        }
        return (out, used)
    }

    /// M9.T05 (AT-254 T3): `fit` with every chunk counted in one batch by the chat model's own tokenizer, so the
    /// budget is real model tokens. The word-based estimate it replaces undercounted (a "10000" T3 block was ~12k
    /// tokens of chat-35b-q4; code and number-heavy pages up to 2x). A count that comes back short falls back to `count`.
    /// Only the ranked prefix that can matter is tokenized: chunks while the cheap `count` total stays ≤ `prefixFactor` ×
    /// the budget (counting every chunk of six pages cost ≈ 0.6 s on T3; while the real count is at least half the
    /// word estimate (a tokenizer has fewer tokens than words / 1.5 only in degenerate text), the prefix holds ≥ the budget).
    public static func fit(_ ranked: [EvidenceChunk], budget: Int, countBatch: BatchCount, count: Count,
                           prefixFactor: Double = 2) async -> (chunks: [EvidenceChunk], tokens: Int) {
        var prefix: [EvidenceChunk] = [], approx = 0
        for c in ranked {
            approx += await count(render(c)) + 1
            if Double(approx) > prefixFactor * Double(budget) { break }
            prefix.append(c)
        }
        let ranked = prefix
        let texts = ranked.map(render)
        let counts = texts.isEmpty ? [] : await countBatch(texts)
        guard counts.count == texts.count else { return await fit(ranked, budget: budget, count: count) }
        var used = 0, out: [EvidenceChunk] = []
        for (c, n) in zip(ranked, counts) {
            let t = n + 1  // + the separating newline
            if used + t <= budget { out.append(c); used += t }
        }
        return (out, used)
    }
}
