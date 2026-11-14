// M6.T01 step 5 (P-files-tools-01): routes a sniffed file to the vendored Osaurus adapters and turns the result into an
// `ExtractedDocument` (Markdown + unit map). PDF → `PDFAdapter` (one unit per page, page numbers kept); DOCX/RTF/HTML →
// `RichDocumentAdapter`; HTML → `HTMLText` (never the AppKit/WebKit importer: it is a loader, M6 review #1); XLSX → `XLSXAdapter` (one unit per
// sheet, as a Markdown table); CSV/TSV → `CSVAdapter`; PPTX → `PPTXAdapter` ("## Slide n" + notes); TXT/MD/code/JSON →
// `PlainTextAdapter`; EPUB → `EPUBAdapter`; images → no text yet (OCR hook M6.T04, VLM hook M6.T05); audio → transcription
// pending (M3.T06, D-026). XLS → `XLSAdapter` (vendored libxls, M6.T07 A-M6-10), same sheet units. Progress goes to `onProgress`
// (0…1) and is mirrored on `progress(_:)` streams.
import AntiChatStorage
import Foundation
import OsaurusVendored
import PDFKit

public enum ExtractionError: Error, Equatable, Sendable {
    /// The kind is not read (yet): legacy doc/ppt, unknown.
    case unsupported(ext: String)
    case encrypted
    case empty
    /// The adapter failed (corrupt file); the reason is for the toast's log line.
    case failed(String)
}

public struct ExtractionProgress: Sendable, Equatable {
    public var fraction: Double
    /// "page n of N" when known (scans, M6.T04).
    public var unit: Int?
    public var units: Int?
    public init(fraction: Double, unit: Int? = nil, units: Int? = nil) {
        self.fraction = fraction; self.unit = unit; self.units = units
    }
}

public actor ExtractionService {
    /// Kinds `extract` reads today (XLS since M6.T07).
    public static func readsNow(_ kind: AttachmentKind) -> Bool { kind.isSupported }

    public init() {}

    public func extract(url: URL, kind: AttachmentKind,
                        onProgress: (@Sendable (ExtractionProgress) -> Void)? = nil) async throws -> ExtractedDocument {
        guard Self.readsNow(kind) else { throw ExtractionError.unsupported(ext: url.pathExtension.lowercased()) }
        onProgress?(.init(fraction: 0))
        let limit = AttachmentLimits.maxFileBytes
        let doc: ExtractedDocument
        do {
            switch kind {
            case .pdf: doc = try await Self.pdf(url, limit: limit)
            case .docx:
                // AppKit's OOXML importer inflates the whole package unbounded: prove it is within the caps first.
                let zip = try BoundedZip(url: url)
                try zip.checkAll()
                doc = try await Self.rich(RichDocumentAdapter().parse(url: url, sizeLimit: limit),
                                          headings: DOCXHeadings.levels(zip))
            case .rtf: doc = try await Self.rich(RichDocumentAdapter().parse(url: url, sizeLimit: limit))
            case .html: doc = try Self.html(url, limit: limit)
            case .xlsx: doc = try await Self.workbook(XLSXAdapter().parse(url: url, sizeLimit: limit))
            case .xls:
                do { doc = try Self.workbook(XLSAdapter.workbook(url: url)) } catch XLSAdapterError.encrypted {
                    throw ExtractionError.encrypted
                } catch XLSAdapterError.empty { throw ExtractionError.empty }
            case .csv: doc = try await Self.csv(CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: limit))
            case .tsv: doc = try await Self.csv(CSVAdapter(delimiter: .tab).parse(url: url, sizeLimit: limit))
            case .pptx: doc = try await Self.slides(PPTXAdapter().parse(url: url, sizeLimit: limit))
            case .text, .markdown, .json, .code: doc = try await Self.plain(url, kind: kind, limit: limit)
            case .epub: doc = try EPUBAdapter().extract(url: url)
            case _ where kind.isImage: doc = ExtractedDocument(markdown: "")
            case _ where kind.isAudio: doc = ExtractedDocument(markdown: "", transcriptionPending: true)
            default: throw ExtractionError.unsupported(ext: url.pathExtension.lowercased())
            }
        } catch let e as ExtractionError {
            throw e
        } catch let z as BoundedZipError {
            throw ExtractionError.failed("zip: \(z)")
        } catch {
            throw ExtractionError.failed(String(describing: error))
        }
        if doc.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !kind.isImage, !kind.isAudio, kind != .pdf {
            throw ExtractionError.empty
        }
        onProgress?(.init(fraction: 1, unit: doc.pageCount, units: doc.pageCount))
        return doc
    }

    // MARK: per format

    static func pdf(_ url: URL, limit: Int64) async throws -> ExtractedDocument {
        let parsed: StructuredDocument
        do {
            parsed = try await PDFAdapter().parse(url: url, sizeLimit: limit)
        } catch DocumentAdapterError.emptyContent {
            // An image-only PDF (a scan): every page is kept, empty, for OCR (M6.T04).
            guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw ExtractionError.empty }
            var md = MarkdownBuilder()
            for i in 0..<pdf.pageCount { md.unit(.page, index: i + 1, "") }
            return md.build()
        }
        guard let rep = parsed.representation.underlying as? PDFDocumentRepresentation else {
            throw ExtractionError.failed("pdf: no page representation")
        }
        // The adapter leaves out pages without a text layer; every page of the file keeps its unit (and number), so a
        // scanned page is there, empty, for M6.T04 to OCR into.
        let count = max(PDFDocument(url: url)?.pageCount ?? 0, (rep.pages.map(\.pageIndex).max() ?? -1) + 1)
        guard count > 0 else { throw ExtractionError.failed("pdf: no pages") }
        let texts = Dictionary(rep.pages.map { ($0.pageIndex, $0.text) }, uniquingKeysWith: { a, _ in a })
        var md = MarkdownBuilder()
        for i in 0..<count {
            md.unit(.page, index: i + 1, (texts[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return md.build()
    }

    /// `headings`: DOCX paragraph text → heading level from `word/document.xml` styles (AppKit's OOXML importer drops
    /// style names, so the adapter sees every DOCX paragraph as body text).
    static func rich(_ parsed: StructuredDocument, headings: [String: Int] = [:]) throws -> ExtractedDocument {
        guard let rep = parsed.representation.underlying as? RichDocumentRepresentation else {
            return ExtractedDocument(markdown: parsed.textFallback)
        }
        var lines: [String] = []
        for b in rep.blocks {
            let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if b.kind == .paragraph, let level = headings[t] {
                lines.append(String(repeating: "#", count: level) + " " + t)
                continue
            }
            switch b.kind {
            case .heading: lines.append(String(repeating: "#", count: max(1, min(6, b.headingLevel ?? 1))) + " " + t)
            case .listItem: lines.append(String(repeating: "  ", count: max(0, (b.listDepth ?? 1) - 1)) + "- " + t)
            case .paragraph: lines.append(t)
            }
        }
        let text = lines.isEmpty ? rep.text : lines.joined(separator: "\n\n")
        var md = MarkdownBuilder()
        md.unit(.section, index: 1, text)
        return md.build()
    }

    /// HTML is parsed as data only (`HTMLText`: libxml2's HTML parser, no loader), so no subresource is ever fetched.
    static func html(_ url: URL, limit: Int64) throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= limit else { throw ExtractionError.failed("html: over the size limit") }
        let text = HTMLText.markdown(try Data(contentsOf: url, options: .alwaysMapped))
        var md = MarkdownBuilder()
        md.unit(.section, index: 1, text)
        return md.build()
    }

    static func workbook(_ parsed: StructuredDocument) throws -> ExtractedDocument {
        guard let wb = parsed.representation.underlying as? Workbook else { return ExtractedDocument(markdown: parsed.textFallback) }
        return try workbook(wb)
    }

    static func workbook(_ wb: Workbook) throws -> ExtractedDocument {
        var md = MarkdownBuilder()
        for (i, sheet) in wb.sheets.enumerated() {
            let cols = sheet.rows.map { $0.cells.map(\.columnNumber).max() ?? 0 }.max() ?? 0
            let rows: [[String]] = sheet.rows.map { row in
                var cells = Array(repeating: "", count: cols)
                for c in row.cells where c.columnNumber >= 1 && c.columnNumber <= cols {
                    let v = c.value.fallbackText
                    cells[c.columnNumber - 1] = v.isEmpty ? c.formula.map { "=" + $0 } ?? "" : v  // uncached formula
                }
                return cells
            }
            md.unit(.sheet, index: i + 1, label: sheet.name, rows: max(0, rows.count - 1),
                    "## Sheet: \(sheet.name)\n\n" + markdownTable(rows))
        }
        return md.build()
    }

    static func csv(_ parsed: StructuredDocument) throws -> ExtractedDocument {
        guard let doc = parsed.representation.underlying as? CSVDocument else { return ExtractedDocument(markdown: parsed.textFallback) }
        let rows = doc.rows.map { $0.cells.map(\.text) }
        var md = MarkdownBuilder()
        md.unit(.sheet, index: 1, label: parsed.filename, rows: max(0, rows.count - 1), markdownTable(rows))
        return md.build()
    }

    static func slides(_ parsed: StructuredDocument) throws -> ExtractedDocument {
        guard let deck = parsed.representation.underlying as? PresentationDocument else {
            return ExtractedDocument(markdown: parsed.textFallback)
        }
        var md = MarkdownBuilder()
        for slide in deck.slides {
            var body = "## Slide \(slide.number)"
            let text = slide.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { body += "\n\n" + text }
            if let notes = slide.speakerNotes?.text.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                body += "\n\nNotes: " + notes
            }
            md.unit(.slide, index: slide.number, body)
        }
        return md.build()
    }

    static func plain(_ url: URL, kind: AttachmentKind, limit: Int64) async throws -> ExtractedDocument {
        // PlainTextAdapter decides by extension; a sniffed text file with an odd name is read directly.
        let text: String
        if PlainTextAdapter().canHandle(url: url, uti: nil) {
            text = try await PlainTextAdapter().parse(url: url, sizeLimit: limit).textFallback
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        var md = MarkdownBuilder()
        if kind == .code || kind == .json {
            let lang = kind == .json ? "json" : url.pathExtension.lowercased()
            md.unit(.section, index: 1, "```\(lang)\n\(text.trimmingCharacters(in: .newlines))\n```")
        } else {
            md.unit(.section, index: 1, text)
        }
        return md.build()
    }

    /// Rows → a Markdown table (first row = header; `|` escaped, newlines flattened).
    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first, !header.isEmpty else { return "" }
        let width = rows.map(\.count).max() ?? header.count
        func line(_ r: [String]) -> String {
            let cells = (r + Array(repeating: "", count: max(0, width - r.count))).map {
                $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + Array(repeating: " --- |", count: width).joined()] + rows.dropFirst().map(line))
            .joined(separator: "\n")
    }
}

/// Heading paragraphs of a DOCX by style (`Title` → 1, `Heading N` → N + 1 under a title, else N), our code over the
/// shared bounded zip reader (M6 review #2) + `XMLParser`.
enum DOCXHeadings {
    static func levels(_ url: URL) throws -> [String: Int] { try levels(BoundedZip(url: url)) }

    static func levels(_ zip: BoundedZip) throws -> [String: Int] {
        guard let xml = try zip.data("word/document.xml") else { return [:] }
        let p = Parser()
        let parser = XMLParser(data: xml)
        parser.delegate = p
        parser.parse()
        return p.levels
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var levels: [String: Int] = [:]
        private var style: String?
        private var text = ""
        private var inText = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "w:p": style = nil; text = ""
            case "w:pStyle": style = attributes["w:val"]
            case "w:t": inText = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:t" { inText = false }
            guard name == "w:p", let style else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let lower = style.lowercased()
            if lower == "title" { levels[t] = 1 }
            else if lower.hasPrefix("heading"), let n = Int(lower.dropFirst(7)) { levels[t] = min(6, n + 1) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string } }
    }
}
