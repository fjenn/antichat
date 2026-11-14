// M7.T01 step 2 (P-files-tools-10): XPath 1.0 over libxml2's forgiving HTML parser, the same parser Kanna wraps
// (K-NEW-ARCH-2). It comes from the macOS SDK's `libxml2` module, so no new package is added; the ddgs XPaths run
// verbatim. Foundation's `XMLDocument(.documentTidyHTML)` was rejected: tidy rewrites HTML5 (`<a><h2>` blocks), which
// breaks Startpage's `./a/@href`.
import Foundation
import libxml2

enum XPathHTML {
    /// One parsed page; frees the libxml2 document on deinit.
    final class Document: @unchecked Sendable {
        fileprivate let doc: htmlDocPtr
        init?(html: Data) {
            let opts = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
                             | HTML_PARSE_NONET.rawValue | HTML_PARSE_COMPACT.rawValue)
            let parsed: htmlDocPtr? = html.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count > 0 else { return nil }
                return htmlReadMemory(base.assumingMemoryBound(to: CChar.self), Int32(raw.count), nil, "utf-8", opts)
            }
            guard let parsed else { return nil }
            doc = parsed
        }
        deinit { xmlFreeDoc(doc) }

        /// Nodes matching `xpath`, evaluated relative to `node` (the document root when nil).
        func nodes(_ xpath: String, from node: xmlNodePtr? = nil) -> [xmlNodePtr] {
            guard let ctx = xmlXPathNewContext(doc) else { return [] }
            defer { xmlXPathFreeContext(ctx) }
            if let node { ctx.pointee.node = node }
            guard let result = xmlXPathEvalExpression(xpath, ctx) else { return [] }
            defer { xmlXPathFreeObject(result) }
            guard let set = result.pointee.nodesetval, set.pointee.nodeNr > 0, let tab = set.pointee.nodeTab else { return [] }
            return (0..<Int(set.pointee.nodeNr)).compactMap { tab[$0] }
        }

        /// ddgs `extract_results`: the joined string values of every node `xpath` selects (text nodes, attributes).
        func text(_ xpath: String, from node: xmlNodePtr) -> String {
            nodes(xpath, from: node).map(Self.content).joined()
        }

        static func content(_ n: xmlNodePtr) -> String {
            guard let c = xmlNodeGetContent(n) else { return "" }
            defer { free(c) }  // xmlFree is the system free unless xmlMemSetup was called (never in this process)
            return String(cString: c)
        }
    }

    /// ddgs BaseSearchEngine.extract_results: one hit per `items` node with non-empty href; whitespace collapsed.
    static func hits(html: Data, xpaths: SearchEngineConfig.XPaths, engine: String, max: Int) -> [(title: String, href: String, body: String)] {
        guard let doc = Document(html: html) else { return [] }
        var out: [(String, String, String)] = []
        for item in doc.nodes(xpaths.items) {
            let href = collapse(doc.text(xpaths.href, from: item))
            guard !href.isEmpty else { continue }
            out.append((collapse(doc.text(xpaths.title, from: item)), href, collapse(doc.text(xpaths.body, from: item))))
            if out.count >= max { break }
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
