// M7.T02 step 4 (R-249 AC2; P-files-tools-10): main text + metadata from a fetched page, on the Mac.
// HTML: trafilatura first (trafilatura-swift@e051b5e562, TrafilaturaFFI.xcframework from trafilatura-rs v0.6.0,
// checksum-pinned), then `ReadabilityFallback` (vendored Osaurus SearchReadability) on error or empty text.
// PDF: PDFKit text (the M6 Knowledge adapter is not reachable from AntiChatTools; same framework underneath).
// Plain text passes through. Nothing here talks to the network.
import Foundation
import OsaurusVendored
import PDFKit

public struct ExtractedPage: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var site: String
    public var text: String
    public var date: String?
    public var author: String?
    public var lang: String?
    /// Which extractor produced `text` (`trafilatura`, `readability`, `pdf`, `plain`).
    public var method: String
}

public protocol HTMLExtractor: Sendable {
    func extract(html: String, url: URL) -> ExtractedPage?
}

public enum Extractor {
    /// The HTML chain: trafilatura (when linked) → Readability. Empty results fall through.
    public static var htmlChain: [any HTMLExtractor] { [TrafilaturaExtractor(), ReadabilityFallback()] }

    public static func extract(_ page: FetchedPage, chain: [any HTMLExtractor] = Extractor.htmlChain) -> ExtractedPage? {
        let host = page.url.host() ?? ""
        switch page.contentType {
        case "application/pdf":
            guard let doc = PDFDocument(data: page.data), let text = doc.string, !text.isEmpty else { return nil }
            let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? page.url.lastPathComponent
            return ExtractedPage(url: page.url, title: title, site: host, text: normalize(text), method: "pdf")
        case "text/plain":
            let text = String(decoding: page.data, as: UTF8.self)
            return ExtractedPage(url: page.url, title: page.url.lastPathComponent, site: host, text: normalize(text), method: "plain")
        default:
            let html = String(decoding: page.data, as: UTF8.self)
            for x in chain {
                if let e = x.extract(html: html, url: page.url), !e.text.isEmpty { return e }
            }
            return nil
        }
    }

    /// Collapses runs of blank lines and trailing spaces.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { acc, l in if !(l.isEmpty && (acc.last?.isEmpty ?? true)) { acc.append(l) } }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<meta property|name=… content=…>` from the head (site name, published date).
    static func meta(_ html: String, _ keys: [String]) -> String? {
        for k in keys {
            let p1 = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: k))[\"'][^>]*content=[\"']([^\"']+)[\"']"
            let p2 = "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: k))[\"']"
            for p in [p1, p2] {
                if let r = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                   let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let g = Range(m.range(at: 1), in: html) {
                    return SearchHTML.decodeHTMLEntities(String(html[g]))
                }
            }
        }
        return nil
    }
}
