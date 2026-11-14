// M6.T09 steps 5–6: the Markdown of a `create_document` spec as a small block tree (swift-markdown parse, GFM tables),
// shared by PDFRenderer (TPPDF) and DOCXRenderer (the JSON this encodes is what `bridge-docx.js` maps to `docx`).
// A paragraph holding only an image becomes an image block (resolved through the spec's `images` refs); an inline
// image elsewhere keeps its alt text. Raw HTML is kept as text (never interpreted).
import Foundation
import Markdown

public struct DocRun: Codable, Sendable, Equatable {
    public var text: String
    public var bold: Bool?
    public var italic: Bool?
    public var code: Bool?
    public var strike: Bool?
    public var link: String?
    public init(text: String, bold: Bool? = nil, italic: Bool? = nil, code: Bool? = nil, strike: Bool? = nil,
                link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.code = code; self.strike = strike; self.link = link
    }
}

public struct DocNode: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case heading, paragraph, list, table, code, quote, image, rule }
    public var type: Kind
    public var level: Int?
    public var runs: [DocRun]?
    /// Paragraph / heading direction (true when its first strong character is Arabic or Hebrew).
    public var rtl: Bool?
    public var ordered: Bool?
    public var start: Int?
    public var items: [[DocNode]]?
    public var header: [[DocRun]]?
    public var rows: [[[DocRun]]]?
    /// Column alignment per table column: "left" | "center" | "right" | nil.
    public var align: [String?]?
    public var text: String?
    public var lang: String?
    public var children: [DocNode]?
    public var ref: String?
    public var alt: String?

    public init(type: Kind) { self.type = type }

    /// The node's plain text (runs or code), for script detection and tests.
    public var plainText: String {
        switch type {
        case .heading, .paragraph: (runs ?? []).map(\.text).joined()
        case .code: text ?? ""
        case .list: (items ?? []).flatMap { $0 }.map(\.plainText).joined(separator: "\n")
        case .quote: (children ?? []).map(\.plainText).joined(separator: "\n")
        case .table: ((header ?? []) + (rows ?? []).flatMap { $0 }).map { $0.map(\.text).joined() }.joined(separator: " ")
        case .image: alt ?? ""
        case .rule: ""
        }
    }
}

public enum DocumentAST {
    public static func parse(_ markdown: String) -> [DocNode] {
        let doc = Document(parsing: markdown)
        return doc.children.flatMap(block)
    }

    static func block(_ m: Markup) -> [DocNode] {
        switch m {
        case let h as Heading:
            var n = DocNode(type: .heading)
            n.level = min(max(h.level, 1), 6)
            n.runs = runs(h.children)
            n.rtl = isRTL(n.plainText) ? true : nil
            return [n]
        case let p as Paragraph:
            let kids = Array(p.children).filter { !(($0 as? Text)?.string.trimmingCharacters(in: .whitespaces).isEmpty ?? false) }
            if kids.count == 1, let img = kids.first as? Markdown.Image {
                var n = DocNode(type: .image)
                n.ref = img.source ?? ""
                n.alt = img.children.compactMap { ($0 as? Text)?.string }.joined()
                return [n]
            }
            var n = DocNode(type: .paragraph)
            n.runs = runs(p.children)
            n.rtl = isRTL(n.plainText) ? true : nil
            return [n]
        case let l as UnorderedList:
            var n = DocNode(type: .list)
            n.ordered = false
            n.items = l.listItems.map { $0.children.flatMap(block) }
            return [n]
        case let l as OrderedList:
            var n = DocNode(type: .list)
            n.ordered = true
            n.start = Int(l.startIndex)
            n.items = l.listItems.map { $0.children.flatMap(block) }
            return [n]
        case let t as Markdown.Table:
            var n = DocNode(type: .table)
            n.header = t.head.cells.map { runs($0.children) }
            n.rows = t.body.rows.map { row in row.cells.map { runs($0.children) } }
            let cols = max(n.header?.count ?? 0, n.rows?.map(\.count).max() ?? 0)
            n.align = (0..<cols).map { i -> String? in
                guard i < t.columnAlignments.count, let a = t.columnAlignments[i] else { return nil }
                switch a { case .left: return "left"; case .center: return "center"; case .right: return "right" }
            }
            return [n]
        case let c as CodeBlock:
            var n = DocNode(type: .code)
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            n.text = code
            n.lang = c.language
            return [n]
        case let q as BlockQuote:
            var n = DocNode(type: .quote)
            n.children = q.children.flatMap(block)
            return [n]
        case is ThematicBreak:
            return [DocNode(type: .rule)]
        case let h as HTMLBlock:
            var n = DocNode(type: .paragraph)
            n.runs = [DocRun(text: h.rawHTML.trimmingCharacters(in: .newlines))]
            return [n]
        default:
            return m.children.flatMap(block)
        }
    }

    static func runs(_ children: some Sequence<Markup>, bold: Bool = false, italic: Bool = false, strike: Bool = false,
                     link: String? = nil) -> [DocRun] {
        var out: [DocRun] = []
        func add(_ text: String, code: Bool = false) {
            guard !text.isEmpty else { return }
            let r = DocRun(text: text, bold: bold ? true : nil, italic: italic ? true : nil, code: code ? true : nil,
                           strike: strike ? true : nil, link: link)
            if let last = out.last, last.bold == r.bold, last.italic == r.italic, last.code == r.code,
               last.strike == r.strike, last.link == r.link {
                out[out.count - 1].text += text
            } else {
                out.append(r)
            }
        }
        for c in children {
            switch c {
            case let t as Text: add(t.string)
            case is SoftBreak: add(" ")
            case is LineBreak: add("\n")
            case let ic as InlineCode: add(ic.code, code: true)
            case let e as Emphasis: out += runs(e.children, bold: bold, italic: true, strike: strike, link: link)
            case let s as Strong: out += runs(s.children, bold: true, italic: italic, strike: strike, link: link)
            case let s as Strikethrough: out += runs(s.children, bold: bold, italic: italic, strike: true, link: link)
            case let l as Markdown.Link: out += runs(l.children, bold: bold, italic: italic, strike: strike, link: l.destination)
            case let i as Markdown.Image: add(i.children.compactMap { ($0 as? Text)?.string }.joined())
            case let h as InlineHTML: add(h.rawHTML)
            default: out += runs(c.children, bold: bold, italic: italic, strike: strike, link: link)
            }
        }
        return merge(out)
    }

    static func merge(_ runs: [DocRun]) -> [DocRun] {
        var out: [DocRun] = []
        for r in runs {
            if let last = out.last, last.bold == r.bold, last.italic == r.italic, last.code == r.code,
               last.strike == r.strike, last.link == r.link {
                out[out.count - 1].text += r.text
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// True when the first strong-direction character of `text` is Arabic or Hebrew (Unicode bidi rule P2, simplified).
    public static func isRTL(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default:
                if s.properties.isAlphabetic { return false }
            }
        }
        return false
    }

    /// Image refs the Markdown uses.
    public static func imageRefs(_ nodes: [DocNode]) -> [String] {
        var out: [String] = []
        func walk(_ n: DocNode) {
            if n.type == .image, let r = n.ref { out.append(r) }
            for c in n.children ?? [] { walk(c) }
            for item in n.items ?? [] { item.forEach(walk) }
        }
        nodes.forEach(walk)
        return out
    }
}
