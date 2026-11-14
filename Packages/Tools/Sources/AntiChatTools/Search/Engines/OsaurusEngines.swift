// M7.T01 (P-files-tools-10): the vendored Osaurus keyless scrapers (osaurus@2922745 Services/Search/
// NativeSearchBackends.swift), configured as AntiChat engines. Only their parsers and challenge checks run here
// (`package` via access-rewrite.txt); the request goes through AntiChat's gated transport, so the safe-search
// parameter and the test rules apply uniformly. Bing is compiled but ships disabled (catalog `enabled: false`).
import Foundation

public enum OsaurusEngines {
    public static let duckduckgo = SearchEngineConfig(
        id: "duckduckgo", name: "DuckDuckGo", enabled: true, kind: .html, parser: .osaurusDDG,
        urlTemplate: "https://html.duckduckgo.com/html/?q={q}&kl=wt-wt",
        safeParam: .init(off: "kp=-2", on: "kp=1"))
    public static let brave = SearchEngineConfig(
        id: "brave", name: "Brave", enabled: true, kind: .html, parser: .osaurusBrave,
        urlTemplate: "https://search.brave.com/search?q={q}&source=web",
        safeParam: .init(off: "safesearch=off", on: "safesearch=strict"))
    public static let bing = SearchEngineConfig(
        id: "bing", name: "Bing", enabled: false, kind: .html, parser: .osaurusBing,
        urlTemplate: "https://www.bing.com/search?q={q}&count=10",
        safeParam: .init(off: "adlt=off", on: "adlt=strict"))
}
