// M7.T03 step 6 (R-250, NFR-SEC5): the untrusted block, numbering across two web steps of one turn, and the
// registry availability that keeps the web tools out of the prompt when search is not available (R-267).
@testable import AntiChatHarness
import AntiChatTools
import Foundation
import Testing

struct WebResultsBlockTests {
    static func results(_ n: Int) -> WebResults {
        let srcs = (1...n).map { WebSource(n: $0, url: "https://s\($0).test/", title: "T\($0)", site: "s\($0).test", date: nil, snippet: "", fetched: $0 != n) }
        let ev = srcs.filter(\.fetched).map { EvidenceChunk(source: $0.n, url: URL(string: $0.url)!, site: $0.site, title: $0.title, text: "body \($0.n)", ordinal: 0) }
        return WebResults(queries: ["q"], sources: srcs, evidence: ev, evidenceTokens: 10, failed: nil)
    }

    @Test func blockIsUntrustedDatedNumberedAndCarriesTheRule() {
        let s = WebResultsBlock.render(Self.results(3), today: Date(timeIntervalSince1970: 1_793_750_400), timeZone: TimeZone(identifier: "UTC")!)
        #expect(s.hasPrefix(#"<web_results untrusted="true" date="2026-11-04">"#) && s.hasSuffix("</web_results>"))
        #expect(s.contains(WebResultsBlock.instruction))
        #expect(s.contains("[1] T1 — s1.test") && s.contains("[2] body 2") && !s.contains("[3] T3"), "unfetched sources are not listed")
    }

    /// AT-250 c2 (M7 bars, bars-2): T0/T1/T3 answers follow the atomic rule after the cite reminder; T2/T4 do not.
    @Test func smallTiersGetTheAtomicCompositionRule() {
        let atomic = WebResultsBlock.render(Self.results(2), atomic: true)
        #expect(atomic.hasSuffix(WebResultsBlock.citeReminder + "\n" + WebResultsBlock.atomicRule + "\n</web_results>"))
        #expect(!WebResultsBlock.render(Self.results(2)).contains(WebResultsBlock.atomicRule))
        #expect(WebResultsBlock.atomicTiers == ["T0", "T1", "T3"])
    }

    /// bars-2 (AT-248 c1): with two or more fetched sources every tier is asked to cite at least two of them.
    @Test func twoFetchedSourcesGetTheSpreadRule() {
        let two = WebResultsBlock.render(Self.results(3))
        #expect(two.hasSuffix(WebResultsBlock.citeReminder + "\n" + WebResultsBlock.spreadRule + "\n</web_results>"))
        #expect(WebResultsBlock.render(Self.results(3), atomic: true).contains(WebResultsBlock.spreadRule + "\n" + WebResultsBlock.atomicRule))
        #expect(!WebResultsBlock.render(Self.results(2)).contains(WebResultsBlock.spreadRule), "one fetched source")
    }

    @Test func secondStepOfATurnContinuesTheNumbering() {
        let store = TurnWebSources()
        _ = store.record(Self.results(3), turn: "t")
        let second = store.record(Self.results(2), turn: "t")
        #expect(second.sources.map(\.n) == [4, 5] && second.evidence.map(\.source) == [4])
        #expect(store.sources(turn: "t").count == 5 && store.sources(turn: "other").isEmpty)
    }

    @Test func webToolsAreUnavailableOfflineAndAvailableOnline() {
        let registry = ToolRegistry()
        let online = WebSearchAvailability(fixed: .available)
        _ = WebSearchTools.install(into: registry, availability: online, tier: { "T1" })
        #expect(registry.tool(named: "web_search")?.isAvailable == true && registry.tool(named: "read_url")?.isAvailable == true)
        #expect(registry.tool(named: "web_search")?.outputIsUntrusted == true && registry.tool(named: "web_search")?.sideEffect == .read)
        let offline = ToolRegistry()
        _ = WebSearchTools.install(into: offline, availability: WebSearchAvailability(fixed: .noNetwork), tier: { "T1" })
        #expect(offline.tool(named: "web_search")?.isAvailable == false)
        #expect(!offline.schemas(forModelKey: "chat-9b-q4").contains { $0.name == "web_search" || $0.name == "read_url" })
    }

    @Test func tierBudgetComesFromTheFile() {
        let b = WebSearchTools.budget(tier: "T1")
        #expect(b.queries == 2 && b.budget.pages == 4 && b.budget.evidenceTokens == 3000 && !b.budget.reranker)
        #expect(WebSearchTools.budget(tier: "T3").budget.reranker)
    }
}
