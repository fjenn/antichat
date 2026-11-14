// M7.T03 steps 3, 4, 6 (R-080, R-248 AC1, R-249, R-250): one `web_search` / `read_url` step end to end:
// broker (T01) → fetch the top pages (T02, tier `pages`) → extract → chunk → rank → fit the tier's evidence budget.
// Sources are numbered 1…n in rank order; `fetched` is true only for a page whose text reached the evidence (a
// snippet-only source counts only when its snippet text is in the evidence). Citations may point only at those.
import AntiChatFoundation
import Foundation
import OsaurusVendored

public struct WebSource: Codable, Sendable, Equatable {
    public var n: Int
    public var url: String
    public var title: String
    public var site: String
    public var date: String?
    public var snippet: String
    /// The page (or its snippet) is in the evidence the model saw.
    public var fetched: Bool
    /// The page's own icon, base64 (≤ 16 KB; `WebSearchPipeline.favicons`), for the hover card. No favicon service.
    public var faviconData: String?
    public init(n: Int, url: String, title: String, site: String, date: String?, snippet: String, fetched: Bool, faviconData: String? = nil) {
        self.n = n; self.url = url; self.title = title; self.site = site; self.date = date; self.snippet = snippet; self.fetched = fetched
        self.faviconData = faviconData
    }
}

public struct WebResults: Sendable, Equatable {
    public var queries: [String]
    public var sources: [WebSource]
    public var evidence: [EvidenceChunk]
    public var evidenceTokens: Int
    public var failed: String?
    /// Icon URL per fetched source `n` (the HTML's `<link rel=icon>`, else `/favicon.ico`), read after the step.
    public var iconURLs: [Int: URL] = [:]
    /// Engines that answered with results / that were blocked or failed (activity detail; K-search-blocking).
    public var engines: [String] = []
    public var blockedEngines: [String] = []
    /// The region hint the search requests carried (shown on the activity line; nil = none).
    public var region: String? = nil
    /// Why a page of the fetched window has no text (url → fetch failure, or "extract" when the page had no main
    /// text); diagnostics only (M7 final: AT-248 c1 retrieval analysis). "late" = not in by the fetch deadline.
    public var fetchFailures: [String: String] = [:]
    /// Seconds from the fetch start until each page of the fetched window was done (url → s; diagnostics, M9.T05).
    public var fetchSeconds: [String: Double] = [:]
    public init(queries: [String], sources: [WebSource], evidence: [EvidenceChunk], evidenceTokens: Int, failed: String?) {
        self.queries = queries; self.sources = sources; self.evidence = evidence; self.evidenceTokens = evidenceTokens; self.failed = failed
    }
}

public struct WebSearchBudget: Sendable, Equatable {
    public var pages: Int, evidenceTokens: Int, raceBudget: Double, reranker: Bool
    /// M9.T05 (AT-254 T3): answer with the pages in by this many seconds after the fetch started; a later page is used
    /// as its snippet (`PageFetcher.fetch(_:deadline:)`). nil = wait for every page (≤ the 5 s page timeout).
    public var fetchDeadline: Double?
    public init(pages: Int, evidenceTokens: Int, raceBudget: Double = 2.5, reranker: Bool = false, fetchDeadline: Double? = nil) {
        self.pages = pages; self.evidenceTokens = evidenceTokens; self.raceBudget = raceBudget; self.reranker = reranker
        self.fetchDeadline = fetchDeadline
    }
}

public struct WebSearchPipeline: Sendable {
    public let broker: SearchBroker
    public let fetcher: PageFetcher
    public let ranker: EvidenceRanker
    public let count: EvidenceBudget.Count

    public init(broker: SearchBroker = SearchBroker(), fetcher: PageFetcher = PageFetcher(cache: DiskWebCache()),
                ranker: EvidenceRanker = EvidenceRanker(), count: @escaping EvidenceBudget.Count = { Chunker.approxTokens($0) }) {
        self.broker = broker; self.fetcher = fetcher; self.ranker = ranker; self.count = count
    }

    /// `countBatch`: the chat model's tokenizer (Harness passes the turn's engine + slot); nil = `count` per chunk.
    public func search(queries: [String], budget: WebSearchBudget, directURL: URL? = nil, freshness: String? = nil,
                       countBatch: EvidenceBudget.BatchCount? = nil) async -> WebResults {
        let sp = Signposts.begin(.searchResults, on: Signposts.harness)
        // M7 verifier: a latest/current-version question also asks the swapped phrasing, and results that state the
        // latest version move into the fetched window (SearchRecency; nothing filtered)
        let recency = SearchRecency.asksLatest(queries)
        let queries = recency ? SearchRecency.queries(queries) : queries
        let set = await broker.search(queries: queries, budget: SearchBudget(raceBudget: budget.raceBudget), freshness: freshness)
        Signposts.end(.searchResults, sp, on: Signposts.harness, meta: ["hits": "\(set.hits.count)", "engines": set.engines.joined(separator: ",")])
        var hits = recency ? SearchRecency.promote(set.hits, window: max(budget.pages, 1)) : set.hits
        if let directURL { hits.insert(SearchHit(title: directURL.absoluteString, url: directURL.absoluteString, snippet: "", engine: "url"), at: 0) }
        // K-search-blocking: an engine that answers with a bot check is never retried; the others' results are used.
        let blocked = Array(Set(set.attempts.filter { !$0.ok }.map(\.provider))).sorted()
        guard !hits.isEmpty else {
            var r = WebResults(queries: queries, sources: [], evidence: [], evidenceTokens: 0, failed: "search.failed")
            r.blockedEngines = blocked
            r.region = set.region
            return r
        }
        var r = await build(hits: hits, query: queries.joined(separator: " "), budget: budget, countBatch: countBatch)
        r.queries = queries
        r.engines = set.engines
        r.region = set.region
        r.blockedEngines = blocked
        return r
    }

    /// `read_url`: that page alone.
    public func read(url: URL, budget: WebSearchBudget, countBatch: EvidenceBudget.BatchCount? = nil) async -> WebResults {
        let hit = SearchHit(title: url.absoluteString, url: url.absoluteString, snippet: "", engine: "url")
        var r = await build(hits: [hit], query: url.absoluteString, budget: WebSearchBudget(pages: 1, evidenceTokens: budget.evidenceTokens),
                          countBatch: countBatch)
        if r.sources.first?.fetched != true { r.failed = "search.readFailed" }
        return r
    }

    func build(hits: [SearchHit], query: String, budget: WebSearchBudget, countBatch: EvidenceBudget.BatchCount? = nil) async -> WebResults {
        let sp = Signposts.begin(.fetchExtract, on: Signposts.harness)
        let top = Array(hits.prefix(max(budget.pages, 1)))
        let fetched = await fetcher.fetch(top.compactMap { URL(string: $0.url) }, deadline: budget.fetchDeadline)
        var byURL: [String: ExtractedPage] = [:], icons: [String: URL] = [:], failures: [String: String] = [:], secs: [String: Double] = [:]
        for r in fetched {
            if let t = r.seconds { secs[r.url.absoluteString] = t }
            guard let p = r.page else { failures[r.url.absoluteString] = r.failure.map { "\($0)" } ?? "none"; continue }
            if let e = Extractor.extract(p) { byURL[r.url.absoluteString] = e } else { failures[r.url.absoluteString] = "extract" }
            icons[r.url.absoluteString] = Self.iconURL(html: p.data, page: p.url)
        }
        Signposts.end(.fetchExtract, sp, on: Signposts.harness, meta: ["pages": "\(top.count)", "extracted": "\(byURL.count)",
                                                                   "late": "\(fetched.filter { $0.failure == .late }.count)",
                                                                   "page_s": fetched.map { $0.seconds.map { String(format: "%.2f", $0) } ?? "late" }.joined(separator: ",")])
        var sources: [WebSource] = [], chunks: [EvidenceChunk] = []
        for (i, h) in hits.prefix(max(budget.pages, 1) + 4).enumerated() {
            let n = i + 1
            let page = byURL[h.url]
            let site = page?.site ?? SearchHTML.sourceDomain(of: h.url) ?? ""
            sources.append(WebSource(n: n, url: h.url, title: page?.title ?? h.title, site: site, date: page?.date ?? h.publishedDate,
                                     snippet: h.snippet, fetched: false))
            if let page {
                chunks += Chunker.chunks(page, source: n)
            } else if !h.snippet.isEmpty, let u = URL(string: h.url) {
                chunks.append(EvidenceChunk(source: n, url: u, site: site, title: h.title, text: "\(h.title) — \(site)\n\(h.snippet)", ordinal: 0))
            }
        }
        let rsp = Signposts.begin(.searchRank, on: Signposts.harness)
        let ranked = await ranker.rank(query: query, chunks: chunks, useReranker: budget.reranker)
        let fit = if let countBatch {
            await EvidenceBudget.fit(ranked, budget: budget.evidenceTokens, countBatch: countBatch, count: count)
        } else {
            await EvidenceBudget.fit(ranked, budget: budget.evidenceTokens, count: count)
        }
        Signposts.end(.searchRank, rsp, on: Signposts.harness, meta: ["chunks": "\(chunks.count)", "kept": "\(fit.chunks.count)"])
        let inEvidence = Set(fit.chunks.map(\.source))
        for i in sources.indices where inEvidence.contains(sources[i].n) { sources[i].fetched = true }
        var r = WebResults(queries: [query], sources: sources, evidence: fit.chunks, evidenceTokens: fit.tokens, failed: nil)
        r.fetchFailures = failures
        r.fetchSeconds = secs
        for s in sources where s.fetched { if let u = icons[s.url] { r.iconURLs[s.n] = u } }
        return r
    }

    // MARK: Favicons (hover card): the page's own icon, never a favicon service.

    static let iconLink = try! NSRegularExpression(
        pattern: #"<link\b[^>]*\brel\s*=\s*["']?(?:shortcut\s+)?icon["']?[^>]*>"#, options: [.caseInsensitive])
    static let href = try! NSRegularExpression(pattern: #"\bhref\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])

    /// The `<link rel=icon href>` of the page's head (first 64 KB), resolved against the page; else `/favicon.ico`.
    static func iconURL(html: Data, page: URL) -> URL? {
        let head = String(decoding: html.prefix(64 * 1024), as: UTF8.self)
        let ns = head as NSString
        if let link = iconLink.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
           let h = href.firstMatch(in: ns.substring(with: link.range), range: NSRange(location: 0, length: link.range.length)) {
            let raw = (ns.substring(with: link.range) as NSString).substring(with: h.range(at: 1))
            if raw.hasPrefix("data:") { return URL(string: raw) }
            if let u = URL(string: raw, relativeTo: page)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { return u }
        }
        guard var c = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/favicon.ico"; c.query = nil; c.fragment = nil
        return c.url
    }

    public static let faviconMaxBytes = 16 * 1024

    /// Fetches each icon (through the fetcher: SSRF guard, gate, cache), keeps the ones ≤ 16 KB that look like an
    /// image, base64. `data:` icons are decoded in place. Bounded by `timeout` so a slow host never holds the turn.
    public func favicons(_ urls: [Int: URL], timeout: Double = 3) async -> [Int: String] {
        var out: [Int: String] = [:], remote: [(Int, URL)] = []
        for (n, u) in urls {
            if u.scheme == "data", let comma = u.absoluteString.firstIndex(of: ",") {
                let meta = u.absoluteString[..<comma], payload = String(u.absoluteString[u.absoluteString.index(after: comma)...])
                let data = meta.contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
                if let data, data.count <= Self.faviconMaxBytes, Self.looksLikeImage(data) { out[n] = data.base64EncodedString() }
            } else { remote.append((n, u)) }
        }
        guard !remote.isEmpty else { return out }
        let urls = remote.map(\.1), fetcher = self.fetcher
        let fetched = await withTaskGroup(of: [PageFetchResult]?.self) { g in
            g.addTask { await fetcher.fetch(urls, images: true) }
            g.addTask { try? await Task.sleep(for: .milliseconds(Int(timeout * 1000))); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? []
        }
        for (i, r) in fetched.enumerated() where i < remote.count {
            if let d = r.page?.data, r.page?.status == 200, d.count <= Self.faviconMaxBytes, Self.looksLikeImage(d) {
                out[remote[i].0] = d.base64EncodedString()
            }
        }
        return out
    }

    /// PNG / ICO / GIF / JPEG / SVG / WebP magic (an HTML error page is not an icon).
    static func looksLikeImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        guard b.count >= 4 else { return false }
        if b[0] == 0x89, b[1] == 0x50 { return true }                       // PNG
        if b[0] == 0, b[1] == 0, b[2] == 1 || b[2] == 2, b[3] == 0 { return true }  // ICO / CUR
        if b[0] == 0x47, b[1] == 0x49 { return true }                       // GIF
        if b[0] == 0xFF, b[1] == 0xD8 { return true }                       // JPEG
        if b.count >= 12, b[0] == 0x52, b[8] == 0x57 { return true }        // RIFF…WEBP
        let head = String(decoding: d.prefix(256), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }
}
