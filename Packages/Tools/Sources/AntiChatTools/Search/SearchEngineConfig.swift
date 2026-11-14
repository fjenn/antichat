// M7.T01 (R-248 AC2, R-253; G-028/G-029; P-files-tools-10/-11): one keyless engine as data. The code defaults live in
// `Engines/*.swift`; a verified catalog `search_engines` section may override URL templates, XPaths and enable flags
// (CatalogEngineConfig), never add an engine kind this build does not compile.
import Foundation
import OsaurusVendored

public struct SearchEngineConfig: Codable, Sendable, Equatable {
    /// `html`: a scraped results page; `declarative`: a JSON API run by the vendored DeclarativeSearchBackend mapper.
    public enum Kind: String, Codable, Sendable { case html, declarative }

    /// How an `html` page is parsed: the vendored Osaurus regex parsers or verbatim ddgs XPaths.
    public enum Parser: String, Codable, Sendable { case osaurusDDG = "osaurus-ddg", osaurusBrave = "osaurus-brave",
                                                    osaurusBing = "osaurus-bing", xpath, declarative }

    /// ddgs `items_xpath` + `elements_xpath` (title, href, body), evaluated as XPath 1.0 over libxml2's HTML tree.
    public struct XPaths: Codable, Sendable, Equatable {
        public var items: String, title: String, href: String, body: String
        public init(items: String, title: String, href: String, body: String) {
            self.items = items; self.title = title; self.href = href; self.body = body
        }
    }

    /// The engine's own safe-search query item for the user option (`k=v`, empty = omit): `off` (the default) or
    /// `on` (the engine's safe value). A parameter, not a check (R-241 AC3).
    public struct SafeParam: Codable, Sendable, Equatable {
        public var off: String, on: String
        public init(off: String, on: String) { self.off = off; self.on = on }
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var kind: Kind
    public var parser: Parser
    /// `{q}` = the percent-encoded query, `{lang}` = the result language (`en`).
    public var urlTemplate: String
    public var xpaths: XPaths?
    /// `declarative` only: the vendored endpoint definition (query params + response key paths).
    public var endpoint: SearchEndpoint?
    /// `declarative` only: builds the hit URL from its title when the API returns none (`{lang}`, `{title}`).
    public var urlFromTitle: String?
    public var safeParam: SafeParam
    /// Hits whose URL starts with one of these are dropped (Startpage's google.com redirects, ddgs post_extract).
    public var dropURLPrefixes: [String]
    public var minAppVersion: String

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind, parser, xpaths, endpoint
        case urlTemplate = "url_template", urlFromTitle = "url_from_title", safeParam = "safe_param"
        case dropURLPrefixes = "drop_url_prefixes", minAppVersion = "min_app_version"
    }

    public init(id: String, name: String, enabled: Bool, kind: Kind, parser: Parser, urlTemplate: String,
                xpaths: XPaths? = nil, endpoint: SearchEndpoint? = nil, urlFromTitle: String? = nil, safeParam: SafeParam,
                dropURLPrefixes: [String] = [], minAppVersion: String = "0.1.0") {
        self.id = id; self.name = name; self.enabled = enabled; self.kind = kind; self.parser = parser
        self.urlTemplate = urlTemplate; self.xpaths = xpaths; self.endpoint = endpoint; self.urlFromTitle = urlFromTitle
        self.safeParam = safeParam; self.dropURLPrefixes = dropURLPrefixes; self.minAppVersion = minAppVersion
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        kind = try c.decode(Kind.self, forKey: .kind)
        parser = try c.decode(Parser.self, forKey: .parser)
        urlTemplate = try c.decode(String.self, forKey: .urlTemplate)
        xpaths = try c.decodeIfPresent(XPaths.self, forKey: .xpaths)
        endpoint = try c.decodeIfPresent(SearchEndpoint.self, forKey: .endpoint)
        urlFromTitle = try c.decodeIfPresent(String.self, forKey: .urlFromTitle)
        safeParam = try c.decode(SafeParam.self, forKey: .safeParam)
        dropURLPrefixes = try c.decodeIfPresent([String].self, forKey: .dropURLPrefixes) ?? []
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "0.1.0"
    }

    /// The host the engine's requests go to (the proxy test's allow-list, AT-248 c2).
    public var host: String? {
        URLComponents(string: urlTemplate.replacingOccurrences(of: "{lang}", with: "en")
            .replacingOccurrences(of: "{q}", with: "q"))?.host
    }
}
