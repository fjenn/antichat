// M7.T01 steps 2–3: one engine = request builder + parser over a `SearchEngineConfig`. Requests are built here (so
// the safe-search parameter and the URL template come from the config) and sent by the broker's transport.
import Foundation
import OsaurusVendored

public struct WebSearchEngine: Sendable {
    public let config: SearchEngineConfig
    public var id: String { config.id }
    public init(_ config: SearchEngineConfig) { self.config = config }

    /// Browser UA from the vendored scrapers (the engines serve their plain HTML pages to browsers).
    static let userAgent = SearchHTTPClient.userAgents[1]
    static var apiUserAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "AntiChat/\(v) (+https://antichat.app/bot)"
    }
    /// RFC 3986 unreserved characters (ASCII only): `&`, `=`, `+`, `#` in a query never split the URL.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `region`: a coarse country hint (SearchRegion; nil = none, the template's worldwide default stays).
    public func request(query: String, safeSearch: Bool, lang: String = "en", timeout: TimeInterval = 5,
                        region: String? = nil, freshness: String? = nil) -> URLRequest? {
        let q = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        var urlString = config.urlTemplate.replacingOccurrences(of: "{lang}", with: lang).replacingOccurrences(of: "{q}", with: q)
        var headers: [String: String] = [:]
        if config.kind == .declarative, var endpoint = config.endpoint {
            endpoint.url = endpoint.url.replacingOccurrences(of: "{lang}", with: lang)
            guard let built = try? DeclarativeSearchBackend.buildRequest(
                endpoint: endpoint, request: SearchRequest(query: query), secrets: [:], providerName: config.name) else { return nil }
            urlString = built.url
            headers = built.headers
        }
        guard var comps = URLComponents(string: urlString) else { return nil }
        if let item = SafeSearch.parameter(for: config, on: safeSearch) {
            comps.queryItems = (comps.queryItems ?? []).filter { $0.name != item.name } + [item]
        }
        if let region, let item = SearchRegion.parameter(engine: config.id, country: region, lang: lang) {
            comps.queryItems = (comps.queryItems ?? []).filter { $0.name != item.name } + [item]
        }
        if let item = SearchFreshness.parameter(engine: config.id, freshness: freshness) {
            comps.queryItems = (comps.queryItems ?? []).filter { $0.name != item.name } + [item]
        }
        guard let url = comps.url else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue(config.kind == .declarative ? "application/json" : "text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // HTML engines get the browser UA their plain pages are served to; JSON APIs get AntiChat's own UA with a contact
        // URL, as Wikimedia's User-Agent policy asks (a bare client UA is throttled with 429).
        r.setValue(config.kind == .html ? Self.userAgent : Self.apiUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Hits from one response. Throws `SearchBackendError` (kind `challenge`, `providerHTTP`, `providerAuth`, `empty`).
    public func parse(status: Int, data: Data, max: Int = 10, lang: String = "en") throws -> [SearchHit] {
        guard status == 200 else {
            throw SearchBackendError("\(config.name) returned status \(status)",
                                     kind: status == 401 || status == 403 || status == 429 ? .providerAuth : .providerHTTP)
        }
        guard !data.isEmpty else { throw SearchBackendError("\(config.name): empty response", kind: .empty) }
        let html = String(decoding: data, as: UTF8.self)
        var hits: [SearchHit]
        switch config.parser {
        case .osaurusDDG:
            if DDGScrapeBackend.isChallengePage(status: status, html: html) { throw challenge() }
            hits = DDGScrapeBackend.parseHTML(html, max: max)
        case .osaurusBrave:
            if SearchHTML.isLikelyChallengePage(html) { throw challenge() }
            hits = BraveScrapeBackend.parseHTML(html, max: max)
        case .osaurusBing:
            if BingScrapeBackend.isChallengePage(html) { throw challenge() }
            hits = BingScrapeBackend.parseHTML(html, max: max)
        case .xpath:
            guard let xp = config.xpaths else { throw SearchBackendError("\(config.name): no xpaths", kind: .providerHTTP) }
            hits = XPathHTML.hits(html: data, xpaths: xp, engine: id, max: max).map {
                SearchHit(title: $0.title, url: SearchHTML.decodeHTMLEntities($0.href), snippet: $0.body, engine: id)
            }
            if hits.isEmpty, SearchHTML.isLikelyChallengePage(html, treatShortAsChallenge: false) || Self.isBotCheck(html) {
                throw challenge()
            }
        case .declarative:
            guard let endpoint = config.endpoint, let json = try? JSONSerialization.jsonObject(with: data) else {
                throw SearchBackendError("\(config.name) returned a non-JSON response", kind: .providerHTTP)
            }
            hits = DeclarativeSearchBackend.mapResponse(json, mapping: endpoint.response, engine: id, maxResults: max)
            if let template = config.urlFromTitle {
                hits = hits.map { h in
                    var h = h
                    if h.url.isEmpty {
                        let t = h.title.replacingOccurrences(of: " ", with: "_")
                            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? h.title
                        h.url = template.replacingOccurrences(of: "{lang}", with: lang).replacingOccurrences(of: "{title}", with: t)
                    }
                    return h
                }
            }
            hits = hits.map { var h = $0; h.snippet = SearchHTML.stripHTML(h.snippet); return h }
        }
        return hits.compactMap { h -> SearchHit? in
            guard h.url.hasPrefix("http"), !config.dropURLPrefixes.contains(where: { h.url.hasPrefix($0) }) else { return nil }
            var h = h
            h.engine = id
            return h
        }
    }

    /// Bot-check interstitials the vendored check does not know (Mojeek's captcha page, Anubis proof-of-work on
    /// Startpage). Detection only: such a page is a failed attempt and the broker moves on (no retry, no solving).
    static func isBotCheck(_ html: String) -> Bool {
        let lc = html.prefix(200_000).lowercased()
        return lc.contains("<title>captcha</title>") || lc.contains("anubis") || lc.contains("verifying your request")
    }

    private func challenge() -> SearchBackendError { SearchBackendError("\(config.name): challenge_page", kind: .challenge) }
}
