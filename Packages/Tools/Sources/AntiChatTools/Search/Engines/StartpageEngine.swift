// Ported from deedy5/ddgs@8e74959141:ddgs/engines/startpage.py (MIT). M7.T01 step 2 (P-files-tools-10): the XPaths
// and `post_extract_results` (drop google.com hrefs) are verbatim; `build_payload` → the URL template. Not ported:
// the `sc` token pre-fetch of the home page and the POST form; AntiChat sends one GET per query (the form's own
// parameters), and a page without results is a failed engine attempt the broker falls through.
import Foundation

public enum StartpageEngine {
    public static let config = SearchEngineConfig(
        id: "startpage", name: "Startpage", enabled: true, kind: .html, parser: .xpath,
        urlTemplate: "https://www.startpage.com/sp/search?query={q}&cat=web&t=device&lui=english&language=english&segment=organic",
        xpaths: .init(items: "//div[contains(@class, 'result css')][./a]",
                      title: ".//h2//text()", href: "./a/@href", body: ".//p//text()"),
        safeParam: .init(off: "qadf=none", on: "qadf=heavy"),
        dropURLPrefixes: ["https://www.google.com"])
}
