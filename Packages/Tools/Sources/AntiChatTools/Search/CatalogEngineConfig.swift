// M7.T01 step 6 (R-253 AC1, NFR-SEC7): the signed catalog's `search_engines` section overrides the code defaults
// (URL templates, XPaths, enable flags). Callers pass only bytes the M2 catalog verifier accepted
// (`CatalogStore.snapshot.verifiedData`); a bad signature therefore never reaches this file and the last good
// configuration stays. An entry for an id this build does not compile is ignored (no engine from data alone, so
// a catalog can never add Google: AT-248 c2).
import Foundation

public enum CatalogEngineConfig {
    public enum ParseError: Error, Equatable { case notJSON, badSection(String) }

    /// The `search_engines` entries of a catalog document; nil when the catalog has no such section.
    public static func section(fromCatalog data: Data) throws -> [SearchEngineConfig]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        guard let raw = root["search_engines"] else { return nil }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: raw)
            return try JSONDecoder().decode([SearchEngineConfig].self, from: bytes)
        } catch { throw ParseError.badSection("\(error)") }
    }

    /// Code defaults with the catalog's entries applied by id (compiled ids only; an entry whose `min_app_version`
    /// is newer than `appVersion` is skipped, keeping the default for that engine).
    public static func merge(defaults: [SearchEngineConfig], overrides: [SearchEngineConfig], appVersion: String) -> [SearchEngineConfig] {
        let byID = Dictionary(overrides.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return defaults.map { d in
            guard let o = byID[d.id], o.parser == d.parser, o.kind == d.kind,
                  appVersion.compare(o.minAppVersion, options: .numeric) != .orderedAscending else { return d }
            return o
        }
    }
}
