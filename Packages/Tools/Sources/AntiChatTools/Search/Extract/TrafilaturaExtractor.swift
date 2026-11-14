// M7.T02 step 4 (R-249 AC2; P-files-tools-10): trafilatura-rs through nchapman/trafilatura-swift@e051b5e562 (Apache-2.0;
// binary target TrafilaturaFFI.xcframework, trafilatura-rs v0.6.0, checksum-pinned in its Package.swift). Main text
// without comments, plus title, site name, date, author and language from its metadata. In-process, no network.
import Foundation
import Trafilatura

public struct TrafilaturaExtractor: HTMLExtractor {
    public init() {}

    public func extract(html: String, url: URL) -> ExtractedPage? {
        var opts = defaultOptions()
        opts.originalUrl = url.absoluteString
        opts.excludeComments = true
        guard let r = try? Trafilatura.extract(html: html, options: opts) else { return nil }
        let text = Extractor.normalize(r.contentText)
        guard !text.isEmpty else { return nil }
        let m = r.metadata
        let site = !m.sitename.isEmpty ? m.sitename : (!m.hostname.isEmpty ? m.hostname : url.host() ?? "")
        return ExtractedPage(url: url, title: m.title.isEmpty ? site : m.title, site: site, text: text, date: m.date,
                             author: m.author.isEmpty ? nil : m.author, lang: m.language.isEmpty ? nil : m.language,
                             method: "trafilatura")
    }
}
