// Ported from deedy5/ddgs@8e74959141:ddgs/engines/mojeek.py (MIT). M7.T01 step 2 (P-files-tools-10): the XPaths are
// verbatim; `build_payload` → the URL template (`q`, page offset `s` is not used: one page per query). ddgs sets
// `safe=1` only when safe search is on; AntiChat sends the catalog's explicit off value (`safe=0`) when off.
// Region cookies (`arc`, `lb`) are not ported: the gate's sessions keep no cookies.
import Foundation

public enum MojeekEngine {
    public static let config = SearchEngineConfig(
        id: "mojeek", name: "Mojeek", enabled: true, kind: .html, parser: .xpath,
        urlTemplate: "https://www.mojeek.com/search?q={q}",
        xpaths: .init(items: "//ul[contains(@class, 'results')]/li",
                      title: ".//h2//text()", href: ".//h2/a/@href", body: ".//p[@class='s']//text()"),
        safeParam: .init(off: "safe=0", on: "safe=1"))
}
