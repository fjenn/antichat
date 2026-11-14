// M6.T09 step 3 (R-273): the file-out tool schemas the model sees. `create_document` makes a PDF, Word (DOCX) or
// Markdown file from Markdown text. T10/T11 add create_spreadsheet / export_table / create_presentation here.
import Foundation

public enum FileOutSchemas {
    public static let createDocumentName = "create_document"

    public static let createDocumentDescription = """
        Create a downloadable document file (PDF, Word .docx or Markdown .md) from Markdown. Use it when the user asks \
        for a file, report, letter, handout or export (slide decks: create_presentation; spreadsheets: create_spreadsheet). Write the full content in `markdown` (headings, lists, tables, \
        code, images as ![alt](ref) where ref is the id of an attached picture, also listed in `images`; no picture \
        attached = no images). The whole call must fit in one reply: keep `markdown` under about 2,000 words and any \
        table to at most 40 rows; for a longer ask write a shortened version and say so. To change a file you made \
        earlier, pass its artifact_id as `revises`. Runs on this Mac; nothing is uploaded.
        """

    public static let createDocumentJSON = #"""
        {"type":"object","properties":{"format":{"type":"string","enum":["pdf","docx","md"],"description":"File type: pdf, docx (Word) or md (Markdown)."},"title":{"type":"string","minLength":1,"maxLength":200,"description":"Document title; also the file name."},"markdown":{"type":"string","minLength":1,"description":"The whole document as Markdown."},"page_size":{"type":"string","enum":["A4","Letter"],"description":"Paper size (default from the user's region)."},"style":{"type":"string","enum":["plain","report"],"description":"plain (sans) or report (serif body)."},"images":{"type":"array","maxItems":20,"items":{"type":"object","properties":{"ref":{"type":"string","minLength":1,"description":"The id of an attached picture (listed in the chat context) or of a file made in this chat."},"alt":{"type":"string"}},"required":["ref"],"additionalProperties":false}},"revises":{"type":"string","description":"artifact_id of a file made earlier in this chat that this replaces with a new version"}},"required":["format","title","markdown"],"additionalProperties":false}
        """#

    public static var createDocumentSchema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(createDocumentJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// `create_document` arguments.
public struct CreateDocumentSpec: Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable, CaseIterable { case pdf, docx, md }
    public enum PageSize: String, Codable, Sendable { case a4 = "A4", letter = "Letter" }
    public enum Style: String, Codable, Sendable { case plain, report }
    public struct Image: Codable, Sendable, Equatable {
        public var ref: String
        public var alt: String?
        public init(ref: String, alt: String? = nil) { self.ref = ref; self.alt = alt }
    }

    public var format: Format
    public var title: String
    public var markdown: String
    public var page_size: PageSize?
    public var style: Style?
    public var images: [Image]?
    /// M6.T10: the artifact this makes a new version of.
    public var revises: String?

    public init(format: Format, title: String, markdown: String, page_size: PageSize? = nil, style: Style? = nil,
                images: [Image]? = nil, revises: String? = nil) {
        self.format = format; self.title = title; self.markdown = markdown; self.page_size = page_size
        self.style = style; self.images = images; self.revises = revises
    }

    /// Letter in the US, Canada, Mexico and the Philippines (and a few more), A4 elsewhere.
    public static func defaultPageSize(locale: Locale = .current) -> PageSize {
        let letter: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "PR", "DO", "CR", "SV", "PA", "NI"]
        return letter.contains(locale.region?.identifier ?? "") ? .letter : .a4
    }

    /// The file name: the title with path-unsafe characters replaced, plus the extension.
    public var filename: String { FileOutNames.filename(title: title, ext: format.rawValue) }
}

public enum FileOutNames {
    public static func filename(title: String, ext: String) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for c in ["/", ":", "\\", "\n", "\r", "\t", "\0"] { base = base.replacingOccurrences(of: c, with: c == "/" || c == ":" ? "-" : " ") }
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Untitled" }
        if base.count > 120 { base = String(base.prefix(120)).trimmingCharacters(in: .whitespaces) }
        let lower = base.lowercased()
        let name = lower.hasSuffix("." + ext) ? base : "\(base).\(ext)"
        return capBytes(name)
    }

    /// APFS names are at most 255 UTF-8 bytes (M6 review #18: 120 CJK characters are ~360): the stem is cut on a
    /// character boundary so the whole name, extension included, is ≤ `limit` bytes.
    public static func capBytes(_ name: String, limit: Int = 240) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > limit { stem.removeLast() }
        stem = stem.trimmingCharacters(in: .whitespaces)
        return (stem.isEmpty ? "file" : stem) + suffix
    }
}
