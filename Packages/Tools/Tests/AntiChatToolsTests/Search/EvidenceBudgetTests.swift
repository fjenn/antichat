// M7.T02 step 7 (AT-249 c2 second half): property test, 200 random result sets × T0…T4: the evidence block never
// exceeds the tier's `search.evidence_tokens` (tier-budgets.json; counted here with a deterministic word tokenizer
// standing in for the engine's), every chunk keeps its source index, and ranking keeps ≥ 2 sources.
@testable import AntiChatTools
import Foundation
import Testing

struct EvidenceBudgetTests {
    /// blueprint B §B1.6 / tier-budgets.json `search.evidence_tokens` (Tools cannot read the Harness resource; the
    /// Harness test DocumentBudgetTests pins the same numbers in the file).
    static let budgets = ["T0": 1500, "T1": 3000, "T2": 6000, "T3": 10000, "T4": 16000]

    struct LCG { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }

    static let words = "the of and printing press river empire light wave cell energy history music city law market data model".split(separator: " ").map(String.init)

    @Test func neverExceedsTheTierBudget() async {
        var rng = LCG(s: 42)
        let count: EvidenceBudget.Count = { s in s.split(whereSeparator: \.isWhitespace).count }
        var cases = 0
        for _ in 0..<200 {
            let sources = 1 + rng.next(8)
            var chunks: [EvidenceChunk] = []
            for src in 1...sources {
                let n = 1 + rng.next(6)
                let page = ExtractedPage(url: URL(string: "https://s\(src).test/p")!, title: "Title \(src)", site: "s\(src).test",
                                         text: (0..<(50 + rng.next(3000))).map { _ in Self.words[rng.next(Self.words.count)] }.joined(separator: " "),
                                         method: "plain")
                chunks += Chunker.chunks(page, source: src).prefix(n)
            }
            let ranked = await EvidenceRanker().rank(query: "printing press history", chunks: chunks, useReranker: false)
            #expect(ranked.count == chunks.count, "ranking keeps every chunk")
            if Set(chunks.map(\.source)).count >= 2 { #expect(Set(ranked.prefix(2).map(\.source)).count == 2) }
            for (tier, budget) in Self.budgets {
                let fit = await EvidenceBudget.fit(ranked, budget: budget, count: count)
                var total = 0
                for c in fit.chunks { total += await count(EvidenceBudget.render(c)) + 1 }
                #expect(total == fit.tokens && fit.tokens <= budget, "\(tier): \(fit.tokens) > \(budget)")
                #expect(fit.chunks.allSatisfy { EvidenceBudget.render($0).hasPrefix("[\($0.source)] ") })
                cases += 1
            }
        }
        #expect(cases == 1000)
    }

    /// M9.T05 (AT-254): with the model's tokenizer (batched) the budget is real tokens — a tokenizer that sees 1.5x
    /// the word estimate keeps fewer chunks and still never passes the budget; a short reply falls back to `count`.
    @Test func batchCountIsTheBudgetsUnit() async {
        let page = ExtractedPage(url: URL(string: "https://x.test/a")!, title: "T", site: "x.test",
                                 text: (0..<6000).map { "w\($0)" }.joined(separator: " "), method: "plain")
        let ranked = Chunker.chunks(page, source: 1)
        let approx: EvidenceBudget.Count = { Chunker.approxTokens($0) }
        let real: EvidenceBudget.BatchCount = { texts in texts.map { Int(Double(Chunker.approxTokens($0)) * 1.5) } }
        let byApprox = await EvidenceBudget.fit(ranked, budget: 3000, count: approx)
        let byReal = await EvidenceBudget.fit(ranked, budget: 3000, countBatch: real, count: approx)
        var realTotal = 0
        for c in byApprox.chunks { realTotal += Int(Double(Chunker.approxTokens(EvidenceBudget.render(c))) * 1.5) + 1 }
        #expect(realTotal > 3000, "the word estimate overfills a real-token budget")
        #expect(byReal.tokens <= 3000 && byReal.chunks.count < byApprox.chunks.count)
        let short = await EvidenceBudget.fit(ranked, budget: 3000, countBatch: { _ in [] }, count: approx)
        #expect(short.tokens == byApprox.tokens && short.chunks.count == byApprox.chunks.count)
    }

    /// M9.T05 (AT-254 T3): six long pages → at most `embedCap` chunks embedded (each source's lead included); every
    /// chunk is still ranked.
    @Test func embeddingIsCappedAndKeepsEverySourcesLead() async {
        final class Seen: @unchecked Sendable { var texts: [String] = [] }
        let seen = Seen()
        var chunks: [EvidenceChunk] = []
        for src in 1...6 {
            let page = ExtractedPage(url: URL(string: "https://s\(src).test/p")!, title: "Lead \(src)", site: "s\(src).test",
                                     text: (0..<9000).map { "w\($0 % 997)" }.joined(separator: " "), method: "plain")
            chunks += Chunker.chunks(page, source: src)
        }
        #expect(chunks.count > 150)
        let r = EvidenceRanker(embed: { texts in seen.texts = texts; return texts.map { _ in [1, 0] } })
        let ranked = await r.rank(query: "w5 w7", chunks: chunks, useReranker: false)
        #expect(ranked.count == chunks.count)
        #expect(seen.texts.count == EvidenceRanker.embedCap + 1, "the query + the cap")
        for src in 1...6 { #expect(seen.texts.contains { $0.hasPrefix("Lead \(src) — ") }) }
    }

    @Test func chunkerSizesAndPrefix() {
        let page = ExtractedPage(url: URL(string: "https://x.test/a")!, title: "T", site: "x.test",
                                 text: (0..<1000).map { "w\($0)" }.joined(separator: " "), method: "plain")
        let c = Chunker.chunks(page, source: 3)
        #expect(c.count >= 3 && c.allSatisfy { $0.text.hasPrefix("T — x.test\n") && $0.source == 3 })
        #expect(c.dropLast().allSatisfy { Chunker.approxTokens($0.text) >= 340 && Chunker.approxTokens($0.text) <= 360 })
        // ≈ 50-token overlap between neighbours.
        let a = Set(c[0].text.split(separator: " ")), b = Set(c[1].text.split(separator: " "))
        #expect(a.intersection(b).count >= 30)
    }

    @Test func bm25AndEmbeddingsFuseAndDomainsAreCapped() async {
        func chunk(_ src: Int, _ host: String, _ text: String) -> EvidenceChunk {
            EvidenceChunk(source: src, url: URL(string: "https://\(host)/x")!, site: host, title: "t", text: text, ordinal: 0)
        }
        let chunks = [chunk(1, "a.test", "printing press invented by Gutenberg"), chunk(1, "a.test", "printing press history"),
                      chunk(1, "a.test", "printing press types"), chunk(2, "b.test", "unrelated cooking"),
                      chunk(3, "c.test", "Gutenberg printing")]
        let ranked = await EvidenceRanker().rank(query: "printing press", chunks: chunks, useReranker: false)
        #expect(ranked.prefix(4).filter { $0.url.host() == "a.test" }.count == 2, "≤ 2 chunks per domain before the overflow")
        #expect(Set(ranked.prefix(2).map(\.source)).count == 2)
        let embed: EvidenceRanker.Embed = { texts in texts.map { $0.contains("cooking") ? [1, 0] : [0, 1] } }
        let withEmbed = await EvidenceRanker(embed: embed).rank(query: "printing press", chunks: chunks, useReranker: false)
        #expect(withEmbed.count == chunks.count)
    }
}
