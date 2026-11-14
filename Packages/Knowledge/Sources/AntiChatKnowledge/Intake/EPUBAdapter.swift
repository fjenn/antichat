// M6.T01 step 6 (P-files-tools-01: "EPUB via ZipArchive + XMLParser is our adapter code"): vendored `ZipArchive` opens
// the book → `META-INF/container.xml` → the OPF `rootfile full-path` → manifest + spine (`XMLParser`) → each XHTML item
// in spine order → a `## <chapter title>` section (unit kind `section`). XHTML is XML, so the chapters go through
// `XMLParser` too instead of the AppKit HTML importer (which must run on the main thread): headings, paragraphs, list
// items and line breaks become Markdown; scripts and styles are dropped.
import AntiChatStorage
import Foundation

public enum EPUBAdapterError: Error, Equatable {
    case notAnEPUB, missingContainer, missingPackage, emptySpine
}

public struct EPUBAdapter: Sendable {
    public init() {}

    public func extract(url: URL) throws -> ExtractedDocument {
        // Every member goes through the shared bounded reader (M6 review #2: per-part and total output caps).
        let zip: BoundedZip
        do { zip = try BoundedZip(url: url) } catch BoundedZipError.notAnArchive { throw EPUBAdapterError.notAnEPUB }
        func member(_ name: String) throws -> Data? { try zip.data(name) }
        guard let container = try member("META-INF/container.xml") else { throw EPUBAdapterError.missingContainer }
        guard let opfPath = ContainerParser.rootfile(container), let opf = try member(opfPath) else {
            throw EPUBAdapterError.missingPackage
        }
        let pkg = PackageParser.parse(opf)
        let base = (opfPath as NSString).deletingLastPathComponent
        var md = MarkdownBuilder()
        var n = 0
        for idref in pkg.spine {
            guard let href = pkg.manifest[idref] else { continue }
            let path = Self.resolve(href, base: base)
            guard let xhtml = try member(path) else { continue }
            let chapter = XHTMLText.parse(xhtml)
            let body = chapter.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            n += 1
            let title = chapter.title ?? "Section \(n)"
            // The chapter's own leading heading becomes the section heading (no duplicate).
            var rest = body
            if let first = chapter.firstHeading, rest.hasPrefix("# \(first)") {
                rest = String(rest.dropFirst(first.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            md.unit(.section, index: n, label: title, "## \(title)" + (rest.isEmpty ? "" : "\n\n\(rest)"))
        }
        guard n > 0 else { throw EPUBAdapterError.emptySpine }
        return md.build()
    }

    static func resolve(_ href: String, base: String) -> String {
        let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        let joined = base.isEmpty ? clean : base + "/" + clean
        var parts: [String] = []
        for p in joined.split(separator: "/") {
            if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - parsers

private final class ContainerParser: NSObject, XMLParserDelegate {
    var path: String?
    static func rootfile(_ data: Data) -> String? {
        let d = ContainerParser()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.path
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if path == nil, local(name) == "rootfile", let fp = attributes["full-path"] { path = fp }
    }
}

private final class PackageParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    static func parse(_ data: Data) -> PackageParser {
        let d = PackageParser()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch local(name) {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        case "itemref":
            if let id = attributes["idref"], attributes["linear"] != "no" { spine.append(id) }
        default: break
        }
    }
}

/// XHTML → Markdown-ish text (headings, paragraphs, list items, breaks); the `<title>` and first heading are kept.
final class XHTMLText: NSObject, XMLParserDelegate {
    var out = ""
    var title: String?
    var firstHeading: String?
    private var inTitle = false, titleBuf = ""
    private var skipDepth = 0
    private var headingBuf: String?
    private var inBody = false

    var markdown: String {
        out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func parse(_ data: Data) -> XHTMLText {
        let d = XHTMLText()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldResolveExternalEntities = false
        p.parse()
        if d.title?.isEmpty ?? true { d.title = d.firstHeading }
        return d
    }

    private func block() { if !out.isEmpty, !out.hasSuffix("\n\n") { out += out.hasSuffix("\n") ? "\n" : "\n\n" } }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        start(local(name))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        end(local(name))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }

    // The element events (also driven by `HTMLText`'s libxml2 tree walk); `n` is the lower-case local name.
    func start(_ n: String) {
        if skipDepth > 0 || n == "script" || n == "style" || n == "noscript" || n == "template" { skipDepth += 1; return }
        switch n {
        case "title": inTitle = true
        case "body": inBody = true
        case "h1", "h2", "h3", "h4", "h5", "h6":
            block()
            out += String(repeating: "#", count: Int(String(n.last!)) ?? 1) + " "
            headingBuf = ""
        case "p", "div", "section", "blockquote", "table", "tr": block()
        case "li": block(); out += "- "
        case "br": out += "\n"
        case "td", "th": out += " "
        default: break
        }
    }

    func end(_ n: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch n {
        case "title": inTitle = false; title = titleBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if firstHeading == nil, let h = headingBuf?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
                firstHeading = h
            }
            headingBuf = nil
            block()
        case "p", "div", "li", "section", "blockquote", "tr": block()
        default: break
        }
    }

    func text(_ string: String) {
        guard skipDepth == 0 else { return }
        if inTitle { titleBuf += string; return }
        guard inBody else { return }
        let collapsed = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if out.hasSuffix("\n") || out.isEmpty || out.hasSuffix("# ") || out.hasSuffix("- ") {
            out += collapsed.drop(while: { $0 == " " })
        } else {
            out += collapsed
        }
        headingBuf? += collapsed
    }
}

private func local(_ name: String) -> String {
    (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
}
