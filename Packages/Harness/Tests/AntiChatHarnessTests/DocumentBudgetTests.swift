// AT-270 checks 1 and 4a (R-270 AC1; M6.T02 step 1): the rule at its ±1-token boundaries, the attach-order rule for
// several documents, and the 200 decisions of fixtures/docs/budget-40 × tier fixtures T0–T4 (budget-40.expected.json,
// made by the Python reference in tools/fixtures/make-budget-set.py) — 100 % must match. Writes
// build/at/AT-270/<date>/decisions.json.
//   make test-unit FILTER=DocumentBudgetTests
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct DocumentBudgetTests {
    static let model = DocumentBudget.Model(contextTokens: 32768, prefillTPS: 2000)
    static let chat = DocumentBudget.ChatState(fixedTokens: 1500, historyTokens: 0)

    @Test func boundariesAtTheContextHalf() {
        // free = 32768 − 1500 − 2048 = 29220 → half = 14610; time cap 40000.
        #expect(DocumentBudget.freeContext(Self.model, Self.chat) == 29220)
        #expect(DocumentBudget.decide(tokens: 14609, model: Self.model, chat: Self.chat).mode == .inline)
        #expect(DocumentBudget.decide(tokens: 14610, model: Self.model, chat: Self.chat).mode == .inline)
        let over = DocumentBudget.decide(tokens: 14611, model: Self.model, chat: Self.chat)
        #expect(over.mode == .excerpts && !over.fitsContext && over.fitsTime && !over.offersReadWhole)
    }

    @Test func boundariesAtTheTimeCap() {
        let slow = DocumentBudget.Model(contextTokens: 131072, prefillTPS: 400)  // cap 8000
        #expect(DocumentBudget.decide(tokens: 7999, model: slow, chat: Self.chat).mode == .inline)
        #expect(DocumentBudget.decide(tokens: 8000, model: slow, chat: Self.chat).mode == .inline)
        let d = DocumentBudget.decide(tokens: 8001, model: slow, chat: Self.chat)
        #expect(d.mode == .excerpts && d.fitsContext && !d.fitsTime && d.offersReadWhole)
        #expect(d.estimateSeconds == 21)  // ⌈8001 / 400⌉
    }

    @Test func reservedAnswerIsAQuarterBelow8K() {
        #expect(DocumentBudget.reservedAnswer(4096) == 1024)
        #expect(DocumentBudget.reservedAnswer(8192) == 2048)
        #expect(DocumentBudget.reservedAnswer(262144) == 2048)
    }

    @Test func severalAttachmentsInAttachOrder() {
        // 10k inline, then 10k no longer fits half of what is left ((29220 − 10000) / 2 = 9610).
        let ds = DocumentBudget.decideAll(tokens: [10_000, 10_000, 3_000], model: Self.model, chat: Self.chat)
        #expect(ds.map(\.mode) == [.inline, .excerpts, .inline])
        // The time budget is shared too.
        let slow = DocumentBudget.Model(contextTokens: 131072, prefillTPS: 400)
        #expect(DocumentBudget.decideAll(tokens: [5000, 5000], model: slow, chat: Self.chat).map(\.mode) == [.inline, .excerpts])
        // Read whole file forces inline only when it fits the context.
        let forced = DocumentBudget.decideAll(tokens: [9000, 60_000], model: slow, chat: Self.chat, forceInline: [0, 1])
        #expect(forced.map(\.mode) == [.inline, .excerpts])
    }

    @Test func tierBudgetsHaveEveryTier() {
        for t in TierBudgets.tiers { #expect(TierBudgets.shared.files.retrievalTopK[t] != nil, "\(t)") }
        #expect(TierBudgets.shared.version == 1)
        #expect(TierBudgets.shared.prefillTPS(modelKey: "chat-9b-q4", tier: "T1") == 2034)
        for t in TierBudgets.tiers { #expect(TierBudgets.shared.files.prefillTPSTierDefault[t] != nil, "\(t)") }
    }

    /// M7.T01 step 0 (A-M7-04): every M7 section carries a blueprint `source` and every row has all five tiers.
    @Test func m7SectionsHaveEveryTierAndASource() throws {
        let b = TierBudgets.shared
        let s = try #require(b.search), t = try #require(b.tools), k = try #require(b.skills), c = try #require(b.connections)
        for src in [s.source, t.source, k.source, c.source] { #expect(src.contains("blueprint B §B")) }
        let intRows: [[String: Int]] = [s.queries, s.pages, s.evidenceTokens, t.maxPerStep, t.schemaTokenCap, t.resultCap,
                                        t.maxSteps, k.candidatesM, k.maxActive, k.bodyTokens, c.maxLocalServers, c.idleShutdownMin]
        for tier in TierBudgets.tiers {
            for row in intRows { #expect(row[tier] != nil, "\(tier)") }
            #expect(s.reranker[tier] != nil && s.freeRaceBudgetS[tier] != nil && k.theta[tier] != nil, "\(tier)")
        }
        // M7.T14 step 1 (A-M7-04): the decoded rows are the file's rows (raw JSON, no retyped numbers).
        let url = try #require(TierBudgets.resourceURL)
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func row(_ section: String, _ key: String) -> [String: Int]? { (raw[section] as? [String: Any])?[key] as? [String: Int] }
        #expect(s.evidenceTokens == row("search", "evidence_tokens") && t.maxPerStep == row("tools", "max_per_step"))
        #expect(t.schemaTokenCap == row("tools", "schema_token_cap") && t.resultCap == row("tools", "result_cap"))
        #expect(t.maxSteps == row("tools", "max_steps") && k.candidatesM == row("skills", "candidates_m"))
        #expect(TierBudgets.cell(s.pages, "T9") == s.pages["T1"])
    }

    /// A-M6-T02a: a chat key missing from tier-budgets.json (a catalog model update) uses the tier's conservative
    /// default: no crash, and the rule leans to excerpts (never more inline than the slowest measured model allows).
    @Test func missingModelKeyFallsBackToConservativeTierDefault() throws {
        let b = TierBudgets.shared
        for t in TierBudgets.tiers {
            let v = b.prefillTPS(modelKey: "chat-new-model-after-catalog-update", tier: t)
            #expect(v == b.files.prefillTPSTierDefault[t])
            #expect(v > 0 && v <= b.files.prefillTPS.values.min()!, "\(t): \(v) must not exceed any measured rate")
        }
        // Unknown tier and no defaults at all → the floor; non-positive values are ignored.
        #expect(b.prefillTPS(modelKey: "x", tier: "T9") == TierBudgets.floorPrefillTPS)
        let broken = TierBudgets(version: 1, files: .init(retrievalTopK: ["T1": 6], prefillTPS: ["m": 0, "n": .nan],  // budget-ok: synthetic
                                                          prefillTPSTierDefault: [:]))
        #expect(broken.prefillTPS(modelKey: "m", tier: "T1") == TierBudgets.floorPrefillTPS)
        #expect(broken.prefillTPS(modelKey: "n", tier: "T1") == TierBudgets.floorPrefillTPS)
        // An old file without the tier section still decodes.
        let old = try JSONDecoder().decode(TierBudgets.self, from: Data(#"{"version":1,"files":{"retrieval_top_k":{"T1":6}}}"#.utf8))  // budget-ok: synthetic
        #expect(old.prefillTPS(modelKey: "chat-9b-q4", tier: "T1") == TierBudgets.floorPrefillTPS)
        // A 15k-token document is inline for chat-9b-q4 (2034 tok/s × 20 s ≈ 40k) but excerpts + [Read whole file]
        // for an unknown key on T1 (500 × 20 = 10k).
        let chat = DocumentBudget.ChatState(fixedTokens: 1000, historyTokens: 0)
        let known = DocumentBudget.Model(contextTokens: 131072, prefillTPS: b.prefillTPS(modelKey: "chat-9b-q4", tier: "T1"))
        let unknown = DocumentBudget.Model(contextTokens: 131072, prefillTPS: b.prefillTPS(modelKey: "chat-x", tier: "T1"))
        #expect(DocumentBudget.decide(tokens: 15_000, model: known, chat: chat).mode == .inline)
        let d = DocumentBudget.decide(tokens: 15_000, model: unknown, chat: chat)
        #expect(d.mode == .excerpts && d.fitsContext && !d.fitsTime && d.offersReadWhole)
    }

    struct Expected: Decodable {
        struct Tier: Decodable { var context_tokens: Int; var prefill_tps: Double; var fixed_tokens: Int; var history_tokens: Int }
        struct D: Decodable { var mode: String; var fitsContext: Bool; var fitsTime: Bool; var estimateSeconds: Int }
        struct Doc: Decodable { var doc: String; var pages: Int; var tokens: Int; var expected: [String: D] }
        var tiers: [String: Tier]
        var docs: [Doc]
    }

    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    @Test func budget40DecisionsMatchTheReference() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("docs/budget-40.expected.json"))
        let e = try JSONDecoder().decode(Expected.self, from: data)
        #expect(e.docs.count == 40)
        #expect(e.docs.contains { $0.doc == "doc-020p.pdf" } && e.docs.contains { $0.doc == "doc-300p.pdf" })
        var rows: [[String: String]] = []
        var matched = 0, total = 0
        for doc in e.docs {
            #expect(FileManager.default.fileExists(atPath: Self.fixtures.appendingPathComponent("docs/budget-40/\(doc.doc)").path))
            for t in TierBudgets.tiers {
                let p = try #require(e.tiers[t])
                let d = DocumentBudget.decide(tokens: doc.tokens,
                                              model: .init(contextTokens: p.context_tokens, prefillTPS: p.prefill_tps),
                                              chat: .init(fixedTokens: p.fixed_tokens, historyTokens: p.history_tokens))
                let want = try #require(doc.expected[t])
                let ok = d.mode.rawValue == want.mode && d.fitsContext == want.fitsContext && d.fitsTime == want.fitsTime
                    && d.estimateSeconds == want.estimateSeconds
                total += 1
                if ok { matched += 1 }
                #expect(ok, "\(doc.doc) \(t): \(d) vs \(want)")
                rows.append(["doc": doc.doc, "tier": t, "tokens": "\(doc.tokens)", "mode": d.mode.rawValue, "ok": "\(ok)"])
            }
        }
        #expect(total == 200 && matched == 200)
        // doc-020p at T0: fits the context, not the time → the excerpt note offers Read whole file (check 2 fixture).
        let d20 = try #require(e.docs.first { $0.doc == "doc-020p.pdf" })
        let t0 = try #require(e.tiers["T0"])
        #expect(DocumentBudget.decide(tokens: d20.tokens, model: .init(contextTokens: t0.context_tokens, prefillTPS: t0.prefill_tps),
                                      chat: .init(fixedTokens: t0.fixed_tokens, historyTokens: 0)).offersReadWhole)
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("build/at/AT-270/\(Date().formatted(.iso8601.year().month().day()))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out: [String: Any] = ["matched": matched, "total": total, "rows": rows]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("decisions.json"))
    }

    /// A-M7-T14a (a), lead decision 2026-11-10: the budget file's per-step tool count agrees with R-235 AC2 (≤ 4 on
    /// T0–T2), so `ToolSelector.cap` is the file's number on every tier.
    @Test func toolsPerStepAgreeWithR235() throws {
        let t = try #require(TierBudgets.shared.tools)
        for tier in ["T0", "T1", "T2"] { #expect((t.maxPerStep[tier] ?? .max) <= ToolPruner.limit, "\(tier)") }
        #expect(t.maxPerStep["T1"] == ToolPruner.limit && t.maxPerStep["T2"] == ToolPruner.limit)
        for tier in [DeviceTier.t0, .t1, .t2, .t3, .t4] {
            let b = ToolSelector.Budget.forTier(tier)
            #expect(ToolSelector.cap(tier, budget: b) == b.maxPerStep, "\(tier)")
        }
    }
}
