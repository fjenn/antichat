// M2.T02 (R-297, G-056; P-platform-08): what a request is for. Every gated session belongs to one category;
// Settings → Privacy & Data shows activity per category and Offline only turns every category off.
// R-297 names: update → `updates`, catalog → `catalog`, model_download → `models`, web_search → `search`,
// connector → `connectors`/`mcp`/`relay`, crash_report → `crashReport`.
import Foundation

public enum NetworkCategory: String, Sendable, Codable, CaseIterable {
    case updates, catalog, models, search, connectors, mcp, relay, crashReport, other
}

/// Untagged requests (a dependency's own session) are categorised by host (M2.T02 step 3).
public enum HostCategoryTable {
    /// The site host (catalog + appcast). Debug: the dev catalog server (`make site-dev`, localhost:4321).
    nonisolated(unsafe) public static var siteHosts: Set<String> = ["antichat.app", "www.antichat.app"]

    public static func lookup(_ host: String?) -> NetworkCategory {
        guard let h = host?.lowercased() else { return .other }
        if h == "huggingface.co" || h.hasSuffix(".huggingface.co") || h == "hf.co" || h.hasSuffix(".hf.co") { return .models }
        if siteHosts.contains(h) { return .catalog }
        return .other
    }
}
