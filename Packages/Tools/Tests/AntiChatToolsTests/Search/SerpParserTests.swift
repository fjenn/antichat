// M7.T01 step 10 (AT-248, DoD "saved-SERP tests for all five engines"): each engine's parser over the first 20 saved
// pages of `fixtures/web/serp-snapshots/<engine>/` (offline). A page the capture recorded as a result page must give
// hits with http(s) URLs and titles; a page it recorded as blocked (429, captcha, Anubis proof-of-work) must give no
// hits and a failed attempt, never junk results. Which pages are which comes from `capture-log.json`.
// The XPath engines also get one small hand-written page each (structure from the ddgs XPaths; marked synthetic),
// because from this Mac Mojeek and Startpage answered every capture with a bot check (capture-log.json).
@testable import AntiChatTools
import Foundation
import OsaurusVendored
import Testing

struct SerpParserTests {
    static let root = ToolsFixtures.url("web/serp-snapshots")

    struct Page { let id: String; let blocked: Bool; let status: Int; let url: URL }

    static func pages(_ engine: String, limit: Int = 20) -> [Page] {
        guard let data = try? Data(contentsOf: root.appending(path: "capture-log.json")),
              let log = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (log[engine] as? [String: Any])?["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r -> Page? in
            guard r["bytes"] != nil, let id = r["id"] as? String else { return nil }
            let ext = engine == "wikipedia" ? "json" : "html"
            return Page(id: id, blocked: r["blocked"] as? Bool ?? true, status: r["status"] as? Int ?? 0,
                        url: root.appending(path: "\(engine)/\(id).\(ext)"))
        }.prefix(limit).map { $0 }
    }

    static func engine(_ id: String) -> WebSearchEngine { WebSearchEngine(EngineRegistry.defaults.first { $0.id == id }!) }

    @Test(arguments: ["duckduckgo", "brave", "mojeek", "startpage", "wikipedia"])
    func savedPagesParseOrFailCleanly(engine id: String) throws {
        let pages = Self.pages(id)
        try #require(!pages.isEmpty, "\(id): no saved pages (run tools/fixtures/make-search-availability.py --capture)")
        let e = Self.engine(id)
        var parsedOK = 0
        for p in pages {
            let data = try Data(contentsOf: p.url)
            let hits = (try? e.parse(status: p.status, data: data)) ?? []
            if p.blocked {
                #expect(hits.isEmpty, "\(id)/\(p.id): a blocked page must not yield results")
                #expect(throws: SearchBackendError.self) { try e.parse(status: p.status, data: data) }
            } else {
                if !hits.isEmpty { parsedOK += 1 }
                for h in hits {
                    #expect(h.url.hasPrefix("http") && !h.title.isEmpty && h.engine == id, "\(id)/\(p.id): \(h)")
                }
            }
        }
        let unblocked = pages.filter { !$0.blocked }.count
        // ≥ 90% of real result pages parse (a query can legitimately have no results).
        #expect(parsedOK * 10 >= unblocked * 9, "\(id): \(parsedOK)/\(unblocked) result pages parsed")
    }

    @Test func duckDuckGoSnapshotsAreRealResultPages() {
        let pages = Self.pages("duckduckgo")
        #expect(pages.filter { !$0.blocked }.count >= 18, "DDG is the parser baseline: most captures must be result pages")
    }

    // Synthetic pages (structure only, from the ddgs XPaths and the vendored Brave parser); not captured SERPs.
    @Test func mojeekXPathsOnASyntheticPage() throws {
        let html = #"""
        <html><body><ul class="results-standard"><li class="r1"><h2><a class="title" href="https://example.com/a">Example <b>A</b></a></h2>
        <p class="s">First <em>snippet</em></p></li><li><h2><a href="https://example.org/b">B</a></h2><p class="s">Second</p></li></ul></body></html>
        """#
        let hits = try Self.engine("mojeek").parse(status: 200, data: Data(html.utf8))
        #expect(hits.map(\.url) == ["https://example.com/a", "https://example.org/b"])
        #expect(hits.map(\.title) == ["Example A", "B"] && hits[0].snippet == "First snippet")
    }

    @Test func startpageXPathsDropGoogleRedirects() throws {
        let html = #"""
        <html><body><div class="w-gl"><div class="result css-1xyz"><a href="https://site.test/x"><h2 class="wgl-title">Start <span>X</span></h2></a>
        <p class="desc">desc x</p></div><div class="result css-2"><a href="https://www.google.com/url?q=1"><h2>G</h2></a><p>g</p></div>
        <div class="result css-3"><p>no link</p></div></div></body></html>
        """#
        let hits = try Self.engine("startpage").parse(status: 200, data: Data(html.utf8))
        #expect(hits.map(\.url) == ["https://site.test/x"])
        #expect(hits.first?.title == "Start X" && hits.first?.snippet == "desc x")
    }

    @Test func braveParserOnASyntheticSnippet() throws {
        let html = #"""
        <html><body><div class="snippet svelte-1" data-type="web"><a href="https://brave.test/page" class="l1"><div class="title">Brave hit</div></a>
        <div class="description">A description</div></div>
        """# + String(repeating: "<p>filler text so the page is not mistaken for a short interstitial</p>", count: 40) + "</body></html>"
        let hits = try Self.engine("brave").parse(status: 200, data: Data(html.utf8))
        #expect(hits.first?.url == "https://brave.test/page" && hits.first?.engine == "brave")
    }

    @Test func statusAndEmptyAnswersAreFailures() {
        let e = Self.engine("duckduckgo")
        #expect(throws: SearchBackendError.self) { try e.parse(status: 403, data: Data()) }
        #expect(throws: SearchBackendError.self) { try e.parse(status: 200, data: Data()) }
        #expect((try? Self.engine("wikipedia").parse(status: 200, data: Data("<html>".utf8))) == nil)
    }
}
