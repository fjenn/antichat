// M6.T09 step 5 (R-273 AC1/AC3, P-files-tools-05, A-M6-01): `create_document` → PDF with TPPDF 2.6.1. The Markdown
// block tree (DocumentAST) becomes TPPDF elements: headings H1–H4 (H5/H6 = H4), paragraphs with bold/italic/code/
// strike/link runs, bullet/numbered lists (nested, drawn as indented paragraphs), GFM tables (header row repeated on
// every page), images (scaled to the text width), code blocks (mono, shaded), quotes, rules. Every page has the title
// in the header and "Page n of N" in the footer; margins 20 mm. Fonts: the bundled Noto set with the script cascade
// (FontRegistry), RTL paragraphs right-aligned with a right-to-left base direction. Metadata Creator "AntiChat",
// Producer "AntiChat <version>" (D-13, written as an incremental update). No WebKit, no process, no network.
import AppKit
import Foundation
import TPPDF

public struct FileOutImage: Sendable {
    public var data: Data
    public var alt: String?
    public init(data: Data, alt: String? = nil) { self.data = data; self.alt = alt }
}

public enum FileOutError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSpec([String])
    case render(String)
    case store(String)

    public var description: String {
        switch self {
        case .invalidSpec(let p): "The file spec is invalid: " + p.joined(separator: "; ")
        case .render(let m): "Rendering failed: \(m)"
        case .store(let m): "Saving the file failed: \(m)"
        }
    }
}

public enum PDFRenderer {
    public static let marginPt: CGFloat = 20 / 25.4 * 72  // 20 mm

    /// Body/heading sizes (pt): body 11, H1 22, H2 17, H3 14, H4 12.
    static func headingSize(_ level: Int) -> CGFloat { [22, 17, 14, 12][min(max(level, 1), 4) - 1] }

    public static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Renders `spec` (format must be .pdf) to PDF bytes. `images` maps a ref to its bytes.
    public static func render(_ spec: CreateDocumentSpec, images: [String: FileOutImage] = [:],
                              locale: Locale = .current) throws -> Data {
        FontRegistry.register()
        let size = spec.page_size ?? CreateDocumentSpec.defaultPageSize(locale: locale)
        let format: PDFPageFormat = size == .letter ? .usLetter : .a4
        let doc = TPPDF.PDFDocument(layout: PDFPageLayout(
            size: format.size,
            margin: NSEdgeInsets(top: marginPt, left: marginPt, bottom: marginPt, right: marginPt),
            space: (header: 14, footer: 14)))
        doc.info = PDFInfo(title: spec.title, author: "AntiChat", subject: "", keywords: [])
        let body = Builder(serif: spec.style == .report, width: format.size.width - 2 * marginPt, images: images)

        // Header (title) and footer ("Page n of N") on every page.
        let small = FontRegistry.font(.sans, size: 8.5, for: spec.title)
        let grey = NSColor(calibratedWhite: 0.42, alpha: 1)
        doc.add(.headerCenter, attributedText: NSAttributedString(string: spec.title, attributes: [.font: small, .foregroundColor: grey]))
        doc.pagination = PDFPagination(container: .footerCenter, style: .customClosure { page, total in "Page \(page) of \(total)" },
                                       textAttributes: [.font: FontRegistry.font(.sans, size: 8.5), .foregroundColor: grey])

        for (i, node) in DocumentAST.parse(spec.markdown).enumerated() {
            if i > 0 { doc.add(space: body.blockGap(before: node)) }
            try body.add(node, to: doc, depth: 0)
        }
        let raw: Data
        do {
            raw = try PDFGenerator(document: doc).generateData()
        } catch {
            throw FileOutError.render("\(error)")
        }
        return stamp(raw, title: spec.title)
    }

    /// Sets the document info (Title, Author/Creator "AntiChat", Producer "AntiChat <version>"). TPPDF writes the host
    /// bundle's name as Creator and Quartz always writes its own Producer, so the info dictionary is replaced by an
    /// incremental update (a new Info object + an xref section — with the free head entry, so readers that expect a
    /// zero-indexed table accept it — + a trailer with /Prev, PDF 1.7 §7.5.6). A file
    /// without a classic xref trailer is returned unchanged.
    static func stamp(_ data: Data, title: String, now: Date = Date()) -> Data {
        let tailCount = min(data.count, 4096)
        let tail = String(decoding: data.suffix(tailCount), as: UTF8.self)
        func first(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        guard let prev = first(#"startxref\s+(\d+)\s+%%EOF\s*$"#, in: tail),
              let trailer = first(#"trailer\s*<<(.*?)>>\s*startxref"#, in: tail),
              let size = first(#"/Size\s+(\d+)"#, in: trailer).flatMap(Int.init),
              let root = first(#"/Root\s+(\d+\s+\d+\s+R)"#, in: trailer) else { return data }
        let id = first(#"(/ID\s*\[[^\]]*\])"#, in: trailer) ?? ""
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        let date = "(D:\(f.string(from: now))Z)"
        var out = data
        if out.last != 0x0A { out.append(0x0A) }
        let objOffset = out.count
        let info = "\(size) 0 obj\n<< /Title \(pdfString(title)) /Author (AntiChat) /Creator (AntiChat) /Producer \(pdfString("AntiChat \(appVersion())")) /CreationDate \(date) /ModDate \(date) >>\nendobj\n"
        out.append(Data(info.utf8))
        let xrefOffset = out.count
        let update = "xref\n0 1\n0000000000 65535 f \n\(size) 1\n\(String(format: "%010d", objOffset)) 00000 n \ntrailer\n<< /Size \(size + 1) /Root \(root) /Info \(size) 0 R /Prev \(prev) \(id) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(update.utf8))
        return out
    }

    /// A PDF text string: literal `( … )` for printable ASCII, else UTF-16BE hex with a BOM.
    static func pdfString(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return "(" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)") + ")"
        }
        return "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    final class Builder {
        let serif: Bool
        let width: CGFloat
        let images: [String: FileOutImage]
        let text = NSColor(calibratedWhite: 0.1, alpha: 1)
        let secondary = NSColor(calibratedWhite: 0.38, alpha: 1)
        let bodySize: CGFloat = 11

        init(serif: Bool, width: CGFloat, images: [String: FileOutImage]) {
            self.serif = serif; self.width = width; self.images = images
        }

        func blockGap(before n: DocNode) -> CGFloat { n.type == .heading ? 10 : 6 }

        var family: FontRegistry.Family { serif ? .serif : .sans }

        func paragraphStyle(rtl: Bool, indent: CGFloat = 0, firstIndent: CGFloat? = nil, spacing: CGFloat = 2) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            p.alignment = rtl ? .right : .left
            p.headIndent = indent
            p.firstLineHeadIndent = firstIndent ?? indent
            p.lineSpacing = spacing
            if indent > 0 { p.tabStops = [NSTextTab(textAlignment: rtl ? .right : .left, location: indent)] }
            p.defaultTabInterval = 18
            return p
        }

        func attributed(_ runs: [DocRun], size: CGFloat, bold: Bool = false, italic: Bool = false,
                        color: NSColor? = nil, family: FontRegistry.Family? = nil) -> NSMutableAttributedString {
            let plain = runs.map(\.text).joined()
            let out = NSMutableAttributedString()
            for r in runs {
                let f: NSFont = r.code == true
                    ? FontRegistry.font(.mono, size: size * 0.92, for: plain)
                    : FontRegistry.font(family ?? self.family, size: size, bold: bold || r.bold == true,
                                        italic: italic || r.italic == true, for: plain)
                var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color ?? text]
                if r.strike == true { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let l = r.link, let url = URL(string: l) {
                    a[.link] = url
                    a[.foregroundColor] = NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.8, alpha: 1)
                }
                out.append(NSAttributedString(string: r.text, attributes: a))
            }
            return out
        }

        /// Right-to-left paragraphs go to TPPDF's right content container (same vertical flow): TPPDF sizes a text frame
        /// to its content, so the paragraph's own right alignment would not move it to the right margin.
        func add(_ n: DocNode, to doc: TPPDF.PDFDocument, depth: Int, listIndent: CGFloat = 0) throws {
            let rtl = n.rtl == true
            switch n.type {
            case .heading:
                let s = attributed(n.runs ?? [], size: PDFRenderer.headingSize(n.level ?? 1), bold: true, family: .sans)
                s.addAttribute(.paragraphStyle, value: paragraphStyle(rtl: rtl, indent: listIndent), range: NSRange(location: 0, length: s.length))
                doc.add(rtl ? .contentRight : .contentLeft, attributedText: s)
            case .paragraph:
                let s = attributed(n.runs ?? [], size: bodySize)
                s.addAttribute(.paragraphStyle, value: paragraphStyle(rtl: rtl, indent: listIndent), range: NSRange(location: 0, length: s.length))
                doc.add(rtl ? .contentRight : .contentLeft, attributedText: s)
            case .list:
                let markers = ["•", "◦", "▪"]
                let indent = listIndent + 18
                for (i, item) in (n.items ?? []).enumerated() {
                    let marker = n.ordered == true ? "\((n.start ?? 1) + i)." : markers[depth % markers.count]
                    var first = true
                    for block in item {
                        if first, block.type == .paragraph {
                            let itemRTL = block.rtl == true
                            let s = NSMutableAttributedString(string: marker + "\t", attributes: [
                                .font: FontRegistry.font(family, size: bodySize), .foregroundColor: text])
                            s.append(attributed(block.runs ?? [], size: bodySize))
                            s.addAttribute(.paragraphStyle, value: paragraphStyle(rtl: itemRTL, indent: indent, firstIndent: listIndent),
                                           range: NSRange(location: 0, length: s.length))
                            doc.add(itemRTL ? .contentRight : .contentLeft, attributedText: s)
                        } else {
                            try add(block, to: doc, depth: block.type == .list ? depth + 1 : depth, listIndent: indent)
                        }
                        first = false
                        doc.add(space: 2)
                    }
                }
            case .table:
                try addTable(n, to: doc)
            case .code:
                let code = n.text ?? ""
                let s = NSMutableAttributedString(string: code.isEmpty ? " " : code, attributes: [
                    .font: FontRegistry.font(.mono, size: 9.5, for: code), .foregroundColor: text,
                    .paragraphStyle: paragraphStyle(rtl: false)])
                let table = PDFTable(rows: 1, columns: 1)
                table.padding = 6
                table.margin = 0
                table.shouldSplitCellsOnPageBreak = true
                let cellStyle = PDFTableCellStyle(colors: (fill: NSColor(calibratedWhite: 0.95, alpha: 1), text: text),
                                                  borders: PDFTableCellBorders(left: .none, top: .none, right: .none, bottom: .none),
                                                  font: FontRegistry.font(.mono, size: 9.5))
                table.style = PDFTableStyle(rowHeaderCount: 0, columnHeaderCount: 0, footerCount: 0, outline: .none,
                                            contentStyle: cellStyle)
                table[0, 0].content = try PDFTableContent(content: s)
                table[0, 0].alignment = .left
                doc.add(table: table)
            case .quote:
                for q in n.children ?? [] {
                    if q.type == .paragraph {
                        let s = attributed(q.runs ?? [], size: bodySize, italic: true, color: secondary)
                        s.addAttribute(.paragraphStyle, value: paragraphStyle(rtl: q.rtl == true, indent: listIndent + 16),
                                       range: NSRange(location: 0, length: s.length))
                        doc.add(q.rtl == true ? .contentRight : .contentLeft, attributedText: s)
                    } else {
                        try add(q, to: doc, depth: depth, listIndent: listIndent + 16)
                    }
                }
            case .image:
                guard let ref = n.ref, let img = images[ref], let ns = NSImage(data: img.data) else {
                    // An unresolved image keeps its alt text (the validator already rejected unknown refs).
                    let s = attributed([DocRun(text: "[\(n.alt ?? "image")]")], size: bodySize, italic: true, color: secondary)
                    doc.add(attributedText: s)
                    return
                }
                let px = ns.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? ns.size
                let natural = px.width > 0 ? px : ns.size
                let w = min(width - listIndent, natural.width * 0.75)  // 96 dpi → pt, never wider than the text
                let h = natural.width > 0 ? w * natural.height / natural.width : natural.height
                let alt = (n.alt?.isEmpty == false ? n.alt : img.alt) ?? ""
                let caption: PDFText? = alt.isEmpty ? nil : PDFAttributedText(text: NSAttributedString(string: alt, attributes: [
                    .font: FontRegistry.font(.sans, size: 9, italic: true, for: alt), .foregroundColor: secondary]))
                doc.add(image: PDFImage(image: ns, caption: caption, size: CGSize(width: w, height: h), sizeFit: .width,
                                        quality: 0.9, options: [.resize, .compress]))
            case .rule:
                doc.addLineSeparator(style: PDFLineStyle(type: .full, color: NSColor(calibratedWhite: 0.8, alpha: 1), width: 0.5))
            }
        }

        func addTable(_ n: DocNode, to doc: TPPDF.PDFDocument) throws {
            let header = n.header ?? []
            let rows = n.rows ?? []
            let cols = max(header.count, rows.map(\.count).max() ?? 0)
            guard cols > 0 else { return }
            let table = PDFTable(rows: rows.count + 1, columns: cols)
            table.padding = 4
            table.margin = 0
            table.showHeadersOnEveryPage = true
            table.shouldSplitCellsOnPageBreak = false
            let border = PDFLineStyle(type: .full, color: NSColor(calibratedWhite: 0.75, alpha: 1), width: 0.5)
            let borders = PDFTableCellBorders(left: border, top: border, right: border, bottom: border)
            let headStyle = PDFTableCellStyle(colors: (fill: NSColor(calibratedWhite: 0.93, alpha: 1), text: text),
                                              borders: borders, font: FontRegistry.font(family, size: 10, bold: true))
            let cellStyle = PDFTableCellStyle(colors: (fill: .white, text: text), borders: borders,
                                              font: FontRegistry.font(family, size: 10))
            table.style = PDFTableStyle(rowHeaderCount: 0, columnHeaderCount: 1, footerCount: 0, outline: border,
                                        columnHeaderStyle: headStyle, contentStyle: cellStyle)
            let align = n.align ?? []
            for r in 0...rows.count {
                for c in 0..<cols {
                    let runs = r == 0 ? (c < header.count ? header[c] : []) : (c < rows[r - 1].count ? rows[r - 1][c] : [])
                    let plain = runs.map(\.text).joined()
                    let rtl = DocumentAST.isRTL(plain)
                    let s = attributed(runs.isEmpty ? [DocRun(text: " ")] : runs, size: 10, bold: r == 0)
                    let a = c < align.count ? align[c] : nil
                    let p = paragraphStyle(rtl: rtl, spacing: 1)
                    if let m = p.mutableCopy() as? NSMutableParagraphStyle {
                        m.alignment = a == "right" ? .right : a == "center" ? .center : (rtl ? .right : .left)
                        s.addAttribute(.paragraphStyle, value: m, range: NSRange(location: 0, length: s.length))
                    }
                    table[r, c].content = try PDFTableContent(content: s)
                    // No per-cell style: TPPDF 2.6.1 drops every row after the first page break when cells carry their
                    // own style; the table style's header/content styles give the same look.
                    table[r, c].alignment = a == "right" ? .right : a == "center" ? .center : (rtl ? .right : .left)
                }
            }
            doc.add(table: table)
        }
    }
}
