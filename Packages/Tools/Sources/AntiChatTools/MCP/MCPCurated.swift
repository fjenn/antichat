// M7.T06 step 8 (R-081 AC4; P-files-tools-12): the "Popular connections" list (`conn.curated.title`). Display-only
// data: nothing connects until the user adds one (R-081 AC1). Source of truth = `catalog/mcp-curated.yaml` → the
// signed catalog's `mcp_curated` section (verified bytes only, NFR-SEC7); until a verified catalog has the section,
// the built-in list below (the same ids, prefilled from the vendored Osaurus `MCPProviderTemplate`) is shown.
// Only entries from a verified catalog count as "curated" for the permission default (a readOnlyHint tool of such a
// server starts on Always allow, R-081 AC2); built-in entries start on Ask like any server.
// CIMD-only entries are hidden until AntiChat's client metadata document is published (M7.T07).
import AntiChatStorage
import Foundation
import OsaurusVendored

public struct MCPCuratedEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    /// `none`, `token` (pasted bearer) or `oauth` (M7.T07).
    public var auth: String
    public var category: String
    public var tagline: String
    public var icon: String
    public var cimdOnly: Bool
    public var helpURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, auth, category, tagline, icon
        case cimdOnly = "cimd_only", helpURL = "help_url"
    }

    public init(id: String, name: String, url: String, auth: String, category: String, tagline: String, icon: String,
                cimdOnly: Bool = false, helpURL: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.auth = auth; self.category = category
        self.tagline = tagline; self.icon = icon; self.cimdOnly = cimdOnly; self.helpURL = helpURL
    }
}

public enum MCPCurated {
    /// The ids of `catalog/mcp-curated.yaml` (remote servers whose auth AntiChat supports: none, bearer, OAuth with
    /// DCR or CIMD; manual-OAuth vendors are left out). Order = display order within a category.
    public static let defaultIDs = [
        "github", "linear", "sentry", "huggingface", "deepwiki", "cloudflare", "vercel", "supabase", "neon", "netlify",
        "notion", "atlassian", "exa_search", "stripe",
    ]

    /// The built-in list (no verified catalog section yet).
    public static let builtIn: [MCPCuratedEntry] = {
        let byID = Dictionary(MCPProviderTemplate.allTemplates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return defaultIDs.compactMap { id in byID[id].map(entry) }
    }()

    static func entry(_ t: MCPProviderTemplate) -> MCPCuratedEntry {
        let auth: String = switch t.authType {
        case .none: "none"
        case .bearerToken: "token"
        case .oauth: "oauth"
        }
        return MCPCuratedEntry(id: t.id, name: t.displayName, url: t.url, auth: auth, category: t.category.displayName,
                               tagline: t.tagline, icon: t.iconSystemName, cimdOnly: t.requiresClientMetadataDocument,
                               helpURL: t.apiKeyHelpURL?.absoluteString)
    }

    public enum ParseError: Error, Equatable { case notJSON, badSection(String) }

    /// The `mcp_curated` entries of a verified catalog document; nil when it has no such section.
    public static func section(fromCatalog data: Data) throws -> [MCPCuratedEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        guard let raw = root["mcp_curated"] else { return nil }
        do {
            return try JSONDecoder().decode([MCPCuratedEntry].self, from: JSONSerialization.data(withJSONObject: raw))
        } catch { throw ParseError.badSection("\(error)") }
    }

    /// What the directory shows: catalog entries when verified, else the built-in list; CIMD-only entries only once
    /// the metadata document is published.
    public static func available(catalog: [MCPCuratedEntry]?, cimdPublished: Bool) -> [MCPCuratedEntry] {
        (catalog ?? builtIn).filter { cimdPublished || !$0.cimdOnly }
    }

    /// The live state the composition root keeps in step with the catalog (`apply(catalogJSON:)`).
    public final class Store: @unchecked Sendable {
        public static let shared = Store()
        private let lock = NSLock()
        private var verified: [MCPCuratedEntry]?
        public init() {}

        /// `data` = `CatalogStore.snapshot.verifiedData` (a bad signature never reaches here; last good kept).
        public func apply(catalogJSON data: Data?) {
            guard let data, let entries = try? MCPCurated.section(fromCatalog: data) else { return }
            lock.withLock { verified = entries }
        }

        public var catalogEntries: [MCPCuratedEntry]? { lock.withLock { verified } }

        public func entries(cimdPublished: Bool = MCPClientMetadata.published) -> [MCPCuratedEntry] {
            MCPCurated.available(catalog: catalogEntries, cimdPublished: cimdPublished)
        }

        /// A curated id the verified catalog lists **at this URL** (the R-081 AC2 trust input). M7.T16 review #4: the
        /// directory pre-fills the add sheet but the URL stays editable, so an id alone would hand the curated
        /// Always-allow default to whatever server the user typed in.
        public func isVerified(_ curatedID: String?, url: String) -> Bool {
            guard let curatedID else { return false }
            let u = MCPCurated.normalized(url)
            return lock.withLock { verified?.contains { $0.id == curatedID && MCPCurated.normalized($0.url) == u } ?? false }
        }

        public func isVerified(_ server: MCPServerRecord) -> Bool { isVerified(server.curatedID, url: server.urlOrCmd) }
    }

    /// Scheme and host lower-cased, default port, trailing slash and fragment dropped (path and query kept).
    public static func normalized(_ url: String) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return url }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        c.fragment = nil
        while c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path == "/" { c.path = "" }
        return c.string ?? url
    }
}

/// M7.T07: whether AntiChat's CIMD document (`site/public/oauth/mcp-client-metadata.json`) is served at its public
/// URL. Until it is, CIMD-only directory entries stay hidden.
public enum MCPClientMetadata {
    nonisolated(unsafe) public static var published = false
}
