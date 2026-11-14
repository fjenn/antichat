// M8.T07 step 5 (R-019 AC1–AC3): a chat's active path as one self-contained HTML file. Inline CSS from the design
// tokens (light), pictures as base64 `data:` URIs, code highlighted (Highlightr colour runs → inline spans), the Evil
// header bar as text ("Evil mode") in `evil.base`. Nothing refers outside the file: links become text with the URL
// in brackets, remote images their alt text, raw HTML is escaped (swift-markdown's HTMLFormatter escapes nothing, so
// this walker renders the AST itself). Math stays as its TeX source in a `math` span (A-M8-T07a).
import AntiChatDesign
import AntiChatStorage
import AppKit
import Foundation
import Markdown

enum ChatHTMLExporter {
    static func html(_ doc: ChatDocument) async -> String {
        var body = ""
        if doc.isEvil {
            body += "<div class=\"evil\" role=\"note\">\(escape(ChatMarkdownRenderer.evilHeader))</div>\n"
        }
        body += "<h1>\(escape(doc.displayTitle))</h1>\n"
        body += "<p class=\"meta\">\(escape(doc.createdAt.formatted(date: .long, time: .shortened)))</p>\n"
        for turn in doc.turns {
            let cls = turn.role == .user ? "user" : "assistant"
            body += "<section class=\"turn \(cls)\">\n<h2>\(escape(ChatMarkdownRenderer.roleHeading(turn.role)))</h2>\n"
            body += await markdownHTML(turn.text)
            for p in turn.pictures {
                if let data = p.data() {
                    body += "<figure><img alt=\"\(escape(p.name))\" src=\"data:\(p.mimeType);base64,\(data.base64EncodedString())\"></figure>\n"
                } else {
                    body += "<p class=\"missing\">[\(escape(p.name))]</p>\n"
                }
            }
            body += "</section>\n"
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="AntiChat">
        <title>\(escape((doc.isEvil ? ChatMarkdownRenderer.evilHeader + " · " : "") + doc.displayTitle))</title>
        <style>\(css())</style>
        </head><body>
        \(body)</body></html>

        """
    }

    // MARK: Markdown → HTML

    static func markdownHTML(_ text: String) async -> String {
        let document = Document(parsing: text)
        var blocks: [(code: String, language: String?)] = []
        collectCode(document, into: &blocks)
        var highlighted: [String?] = []
        for b in blocks {
            if let a = await CodeHighlighter.shared.highlight(b.code, language: b.language, dark: false) {
                highlighted.append(spans(a))
            } else {
                highlighted.append(nil)
            }
        }
        var w = SafeHTMLWriter(highlighted: highlighted)
        w.visit(document)
        return w.result
    }

    static func collectCode(_ m: Markup, into out: inout [(code: String, language: String?)]) {
        if let c = m as? CodeBlock { out.append((c.code, c.language)) }
        for child in m.children { collectCode(child, into: &out) }
    }

    /// Highlightr colour runs as escaped `<span style="color:#rrggbb">`.
    static func spans(_ a: AttributedString) -> String {
        var out = ""
        for run in a.runs {
            let text = escape(String(a[run.range].characters))
            if let c = run.appKit.foregroundColor?.usingColorSpace(.sRGB) {
                out += "<span style=\"color:\(hex(c))\">\(text)</span>"
            } else {
                out += text
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }

    /// Light token values (the file is read anywhere, so it carries one fixed look).
    static func css() -> String {
        var colors: [String: String] = [:]
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            colors = ["text": hex(.textPrimary), "muted": hex(.textSecondary), "canvas": hex(.surfaceCanvas),
                      "raised": hex(.surfaceSunken), "border": hex(.borderSubtle), "evil": hex(.evilBase), "onEvil": hex(.evilOnBase)]
        }
        return """
        body{margin:0 auto;max-width:760px;padding:32px 20px;background:\(colors["canvas"] ?? "#fff");color:\(colors["text"] ?? "#0d0d0d");\
        font:16px/1.55 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}\
        h1{font-size:24px;margin:0 0 4px}.meta{color:\(colors["muted"] ?? "#666");margin:0 0 24px;font-size:13px}\
        .turn{margin:0 0 24px}.turn h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:\(colors["muted"] ?? "#666");margin:0 0 6px}\
        .turn.user{background:\(colors["raised"] ?? "#f4f4f4");border-radius:14px;padding:12px 16px}\
        pre{background:\(colors["raised"] ?? "#f4f4f4");border:1px solid \(colors["border"] ?? "#ddd");border-radius:8px;padding:12px;overflow:auto}\
        code{font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}table{border-collapse:collapse}\
        th,td{border:1px solid \(colors["border"] ?? "#ddd");padding:4px 8px}blockquote{margin:0;padding-left:12px;border-left:3px solid \(colors["border"] ?? "#ddd")}\
        img{max-width:100%;border-radius:8px}figure{margin:8px 0}.math{font-family:ui-monospace,Menlo,monospace}\
        .evil{background:\(colors["evil"] ?? "#b3261e");color:\(colors["onEvil"] ?? "#fff");font-weight:600;padding:8px 14px;border-radius:8px;margin:0 0 16px}
        """
    }
}

/// Renders the swift-markdown AST with every text escaped and nothing pointing outside the file.
struct SafeHTMLWriter: MarkupWalker {
    var result = ""
    let highlighted: [String?]
    private var codeIndex = 0
    private var inHead = false

    init(highlighted: [String?]) { self.highlighted = highlighted }

    private func e(_ s: String) -> String { ChatHTMLExporter.escape(s) }

    mutating func wrap(_ tag: String, _ m: Markup, attrs: String = "") {
        result += "<\(tag)\(attrs)>"
        descendInto(m)
        result += "</\(tag)>"
    }

    mutating func visitParagraph(_ p: Paragraph) { wrap("p", p); result += "\n" }
    mutating func visitHeading(_ h: Heading) { wrap("h\(min(6, h.level + 2))", h); result += "\n" }
    mutating func visitBlockQuote(_ q: BlockQuote) { wrap("blockquote", q); result += "\n" }
    mutating func visitThematicBreak(_ t: ThematicBreak) { result += "<hr>\n" }
    mutating func visitHTMLBlock(_ h: HTMLBlock) { result += "<pre>\(e(h.rawHTML))</pre>\n" }
    mutating func visitCodeBlock(_ c: CodeBlock) {
        let lang = c.language.map { " class=\"language-\(e($0))\"" } ?? ""
        let body = codeIndex < highlighted.count ? (highlighted[codeIndex] ?? e(c.code)) : e(c.code)
        codeIndex += 1
        if let l = c.language?.lowercased(), ["math", "latex", "tex"].contains(l) {
            result += "<div class=\"math\">\(e(c.code))</div>\n"
        } else {
            result += "<pre><code\(lang)>\(body)</code></pre>\n"
        }
    }
    mutating func visitOrderedList(_ l: OrderedList) { wrap("ol", l, attrs: l.startIndex != 1 ? " start=\"\(l.startIndex)\"" : ""); result += "\n" }
    mutating func visitUnorderedList(_ l: UnorderedList) { wrap("ul", l); result += "\n" }
    mutating func visitListItem(_ i: ListItem) {
        result += "<li>"
        if let c = i.checkbox { result += c == .checked ? "☑ " : "☐ " }
        descendInto(i)
        result += "</li>\n"
    }
    mutating func visitTable(_ t: Table) { wrap("table", t); result += "\n" }
    mutating func visitTableHead(_ h: Table.Head) { inHead = true; result += "<thead><tr>"; descendInto(h); result += "</tr></thead>"; inHead = false }
    mutating func visitTableBody(_ b: Table.Body) { wrap("tbody", b) }
    mutating func visitTableRow(_ r: Table.Row) { wrap("tr", r) }
    mutating func visitTableCell(_ c: Table.Cell) { wrap(inHead ? "th" : "td", c) }
    mutating func visitText(_ t: Markdown.Text) { result += mathSpans(t.string) }
    mutating func visitInlineCode(_ c: InlineCode) { result += "<code>\(e(c.code))</code>" }
    mutating func visitEmphasis(_ m: Emphasis) { wrap("em", m) }
    mutating func visitStrong(_ m: Strong) { wrap("strong", m) }
    mutating func visitStrikethrough(_ m: Strikethrough) { wrap("del", m) }
    mutating func visitInlineHTML(_ h: InlineHTML) { result += e(h.rawHTML) }
    mutating func visitLineBreak(_ l: LineBreak) { result += "<br>\n" }
    mutating func visitSoftBreak(_ s: SoftBreak) { result += "\n" }
    mutating func visitSymbolLink(_ s: SymbolLink) { result += "<code>\(e(s.destination ?? ""))</code>" }
    mutating func visitInlineAttributes(_ a: InlineAttributes) { descendInto(a) }
    mutating func visitLink(_ l: Markdown.Link) {
        // No links out of the file (AT-019: 0 external href): the label, then the address as text.
        descendInto(l)
        if let d = l.destination, !d.isEmpty, d != l.plainText { result += " <span class=\"url\">(\(e(d)))</span>" }
    }
    mutating func visitImage(_ i: Markdown.Image) {
        if let s = i.source, s.hasPrefix("data:image/") {
            result += "<img alt=\"\(e(i.plainText))\" src=\"\(e(s))\">"
        } else {
            result += "[\(e(i.plainText))]"
        }
    }

    /// `$…$` / `$$…$$` / `\(…\)` / `\[…\]` as TeX source in a `math` span; the rest escaped.
    func mathSpans(_ s: String) -> String {
        guard s.contains("$") || s.contains("\\(") || s.contains("\\[") else { return e(s) }
        let pattern = #"\$\$(.+?)\$\$|\$([^$\n]+?)\$|\\\((.+?)\\\)|\\\[(.+?)\\\]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return e(s) }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += e(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += "<span class=\"math\">\(e(ns.substring(with: m.range)))</span>"
            last = m.range.location + m.range.length
        }
        out += e(ns.substring(from: last))
        return out
    }
}
