// M7.T02 step 4: the vendored Osaurus readability extractor (osaurus@2922745 Services/Search/SearchReadability.swift,
// `package` via access-rewrite.txt) as AntiChat's HTML extractor: boilerplate tags stripped, the main container picked,
// rendered as Markdown; here turned back into plain text (links → their text, no Markdown markers).
import Foundation
import OsaurusVendored

public struct ReadabilityFallback: HTMLExtractor {
    public init() {}

    public func extract(html: String, url: URL) -> ExtractedPage? {
        let e = SearchReadability.extract(html: html, sourceURL: url)
        guard e.status == .ok else { return nil }
        let text = Extractor.normalize(Self.plain(e.markdown))
        guard !text.isEmpty else { return nil }
        let site = Extractor.meta(html, ["og:site_name", "application-name"]) ?? url.host() ?? ""
        let date = Extractor.meta(html, ["article:published_time", "og:published_time", "date", "pubdate", "DC.date.issued"])
        return ExtractedPage(url: url, title: e.title ?? site, site: site, text: text, date: date, author: e.byline,
                             lang: e.lang, method: "readability")
    }

    /// Markdown → plain text: images dropped, links keep their text, heading / list / emphasis / code markers removed.
    static func plain(_ md: String) -> String {
        var s = md
        let rules: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),            // images
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),         // links
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),            // headings
            (#"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, ""),       // list markers
            (#"(?m)^\s*>\s?"#, ""),                     // quotes
            (#"(\*\*|__|\*|_|`{1,3})"#, ""),            // emphasis / code
            (#"(?m)^\s*([-*_]\s*){3,}$"#, ""),          // rules
        ]
        for (p, t) in rules {
            if let r = try? NSRegularExpression(pattern: p) {
                s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
            }
        }
        return s
    }
}
