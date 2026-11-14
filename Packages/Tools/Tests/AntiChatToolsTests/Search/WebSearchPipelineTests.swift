// M7.T03 steps 3–4/6: broker → fetch → extract → rank → budget with stub transports (no network): numbering,
// `fetched` only for evidence sources, snippet-only fallback, read_url, availability states.
@testable import AntiChatTools
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import Testing

struct WebSearchPipelineTests {
    static let article = "<html><head><title>Printing press</title></head><body><article>" +
        String(repeating: "<p>The printing press was invented by Johannes Gutenberg around 1440 in Mainz, Germany, and changed how books were made.</p>", count: 12) +
        "</article></body></html>"

    static func pipeline(pages: [String: ScriptedPageTransport.Answer]) -> (WebSearchPipeline, ScriptedPageTransport) {
        let urls = ["https://one.test/a", "https://two.test/b", "https://three.test/c"]
        let t = ScriptedPageTransport(pages)
        let broker = SearchBroker(registry: StubEngines.registry, transport: StubTransport(["a": .hits(urls)]), safeSearch: { false })
        let fetcher = PageFetcher(ssrf: SSRFGuard(resolve: { _ in ["93.184.216.34"] }), transport: t)
        return (WebSearchPipeline(broker: broker, fetcher: fetcher), t)
    }

    @Test func sourcesAreNumberedAndOnlyEvidenceSourcesAreFetched() async {
        let (p, _) = Self.pipeline(pages: ["https://one.test/a": .page(Self.article), "https://two.test/b": .status(500)])
        let r = await p.search(queries: ["printing press"], budget: WebSearchBudget(pages: 2, evidenceTokens: 3000))
        #expect(r.sources.map(\.n) == [1, 2, 3])
        #expect(r.sources[0].fetched, "the fetched article is in the evidence")
        #expect(r.sources[0].title == "Printing press")
        #expect(r.sources[1].fetched, "a failed page with a snippet counts once its snippet is in the evidence")
        #expect(r.evidenceTokens <= 3000 && !r.evidence.isEmpty)
        #expect(Set(r.evidence.map(\.source)).isSubset(of: Set(r.sources.filter(\.fetched).map(\.n))))
    }

    @Test func tinyBudgetLeavesSourcesUnfetched() async {
        let (p, _) = Self.pipeline(pages: ["https://one.test/a": .page(Self.article)])
        let r = await p.search(queries: ["printing press"], budget: WebSearchBudget(pages: 1, evidenceTokens: 10))
        #expect(r.evidence.isEmpty && r.sources.allSatisfy { !$0.fetched })
    }

    // MARK: M9.T05 (AT-254 T3): the fetch deadline

    @Test func aPageLaterThanTheDeadlineIsItsSnippetAndStillReachesTheCache() async throws {
        let urls = ["https://one.test/a", "https://two.test/b", "https://three.test/c"]
        let t = ScriptedPageTransport(["https://one.test/a": .page(Self.article), "https://two.test/b": .slow(4.0, Self.article)])
        let cache = MemoryWebCache()
        let broker = SearchBroker(registry: StubEngines.registry, transport: StubTransport(["a": .hits(urls)]), safeSearch: { false })
        let p = WebSearchPipeline(broker: broker, fetcher: PageFetcher(ssrf: SSRFGuard(resolve: { _ in ["93.184.216.34"] }), transport: t, cache: cache))
        let t0 = ContinuousClock.now
        let r = await p.search(queries: ["printing press"], budget: WebSearchBudget(pages: 2, evidenceTokens: 3000, fetchDeadline: 0.4))
        #expect(ContinuousClock.now - t0 < .seconds(3.5), "the turn does not wait for the slow page (4 s)")
        #expect(r.fetchFailures["https://two.test/b"] == "late")
        #expect(r.sources[0].fetched && r.sources[0].title == "Printing press")
        #expect(r.sources[1].title != "Printing press", "the late page is its search result (snippet), not the page")
        #expect(r.fetchSeconds["https://one.test/a"] != nil && r.fetchSeconds["https://two.test/b"] == nil)
        // its fetch was not cancelled: it lands in the page cache for the next turn
        let deadline = ContinuousClock.now + .seconds(10)
        while cache.get(URL(string: "https://two.test/b")!) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(cache.get(URL(string: "https://two.test/b")!) != nil)
    }

    @Test func everyPageInBeforeTheDeadlineReturnsAtOnce() async {
        let (p, _) = Self.pipeline(pages: ["https://one.test/a": .page(Self.article), "https://two.test/b": .page(Self.article)])
        let t0 = ContinuousClock.now
        let r = await p.search(queries: ["printing press"], budget: WebSearchBudget(pages: 2, evidenceTokens: 3000, fetchDeadline: 10))
        #expect(ContinuousClock.now - t0 < .seconds(6), "no wait for the 10 s deadline once every page is in")
        #expect(r.fetchFailures.isEmpty && r.sources.prefix(2).allSatisfy(\.fetched))
    }

    @Test func readURLFetchesThatPageFirstAndOnly() async {
        let (p, t) = Self.pipeline(pages: ["https://given.test/x": .page(Self.article)])
        let r = await p.read(url: URL(string: "https://given.test/x")!, budget: WebSearchBudget(pages: 4, evidenceTokens: 3000))
        #expect(r.failed == nil && r.sources.count == 1 && r.sources[0].fetched)
        #expect(t.requested.filter { !$0.hasSuffix("robots.txt") } == ["https://given.test/x"])
    }

    @Test func availabilityFollowsSwitchOfflineOnlyAndPath() {
        let d = UserDefaults.inMemory()
        let policy = NetworkPolicyStore(defaults: d)
        #expect(WebSearchAvailability(policy: policy, path: PathStatus(fake: "ok")).state == .available)
        #expect(WebSearchAvailability(policy: policy, path: PathStatus(fake: "none")).state == .noNetwork)
        policy.setEnabled(.search, false)
        #expect(WebSearchAvailability(policy: policy, path: PathStatus(fake: "ok")).state == .switchedOff)
        policy.setEnabled(.search, true)
        policy.offlineOnly = true
        let a = WebSearchAvailability(policy: policy, path: PathStatus(fake: "ok"))
        #expect(a.state == .offlineOnly && a.unavailableKey == "network.blockedByOfflineOnly")
    }

    // MARK: M7.T03 hover-card favicons (the page's own icon, ≤ 16 KB, never a favicon service)

    @Test func iconURLFromTheHeadElseFaviconIco() {
        let page = URL(string: "https://news.test/a/b?c=1")!
        let html = Data(#"<html><head><link rel="shortcut icon" href="/static/i.png"></head></html>"#.utf8)
        #expect(WebSearchPipeline.iconURL(html: html, page: page)?.absoluteString == "https://news.test/static/i.png")
        #expect(WebSearchPipeline.iconURL(html: Data("<html></html>".utf8), page: page)?.absoluteString == "https://news.test/favicon.ico")
        let data = Data(#"<link rel=icon href="data:image/png;base64,iVBORw0KGgo=">"#.utf8)
        #expect(WebSearchPipeline.iconURL(html: data, page: page)?.scheme == "data")
    }

    @Test func faviconsKeepSmallImagesOnly() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 64))
        let big = Data([0x89, 0x50] + [UInt8](repeating: 0, count: 20_000))
        let (p, _) = Self.pipeline(pages: ["https://one.test/favicon.ico": .typed("image/png", png), "https://two.test/favicon.ico": .typed("image/png", big),
                                           "https://three.test/favicon.ico": .page("<html>not an icon</html>")])
        let icons = await p.favicons([1: URL(string: "https://one.test/favicon.ico")!, 2: URL(string: "https://two.test/favicon.ico")!,
                                      3: URL(string: "https://three.test/favicon.ico")!,
                                      4: URL(string: "data:image/png;base64,\(png.base64EncodedString())")!])
        #expect(Set(icons.keys) == [1, 4], "over 16 KB and HTML are not icons")
        #expect(icons[1] == png.base64EncodedString())
    }
}
