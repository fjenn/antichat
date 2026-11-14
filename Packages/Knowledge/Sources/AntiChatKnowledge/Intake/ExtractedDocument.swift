// M6.T01 step 5/10: what intake extracted from a file: Markdown + a unit map (page / sheet / slide / section, each a
// UTF-16 range of the Markdown) + counts. Stored as `…/Media/extracted/<sha256>.md` (in memory for incognito) with the
// unit map in `attachment.page_map_json`. The prompt layer always wraps it as untrusted (NFR-SEC5; M6.T02 places it).
import AntiChatFoundation
import Foundation

public struct ExtractedDocument: Codable, Sendable, Equatable {
    public enum UnitKind: String, Codable, Sendable { case page, sheet, slide, section }

    public struct Unit: Codable, Sendable, Equatable {
        public var kind: UnitKind
        /// 1-based (page 1, slide 1, sheet 1, section 1).
        public var index: Int
        /// Sheet name / chapter title / nil.
        public var label: String?
        /// UTF-16 offsets into `markdown`.
        public var start: Int
        public var end: Int
        /// Data rows of a sheet (header excluded).
        public var rows: Int?

        public init(kind: UnitKind, index: Int, label: String? = nil, start: Int, end: Int, rows: Int? = nil) {
            self.kind = kind; self.index = index; self.label = label; self.start = start; self.end = end; self.rows = rows
        }
    }

    public var markdown: String
    public var units: [Unit]
    /// Characters of `markdown` (grapheme clusters).
    public var charCount: Int
    /// Tokens by the active model's tokenizer — a placeholder until M6.T02's `CountTokens` fills it.
    public var tokenCount: Int?
    /// Audio: the text comes from transcription (M3.T06, D-026), not yet available.
    public var transcriptionPending: Bool

    public init(markdown: String, units: [Unit] = [], tokenCount: Int? = nil, transcriptionPending: Bool = false) {
        self.markdown = markdown
        self.units = units
        self.charCount = markdown.count
        self.tokenCount = tokenCount
        self.transcriptionPending = transcriptionPending
    }

    public var pageCount: Int? { count(.page) }
    public var slideCount: Int? { count(.slide) }
    public var sheetCount: Int? { count(.sheet) }
    public var rowCount: Int? { units.contains { $0.kind == .sheet } ? units.compactMap(\.rows).reduce(0, +) : nil }

    private func count(_ kind: UnitKind) -> Int? {
        let n = units.filter { $0.kind == kind }.count
        return n > 0 ? n : nil
    }

    /// The text of one unit.
    public func text(of unit: Unit) -> String {
        let u = markdown.utf16
        let lo = u.index(u.startIndex, offsetBy: min(unit.start, u.count))
        let hi = u.index(u.startIndex, offsetBy: min(unit.end, u.count))
        return String(markdown[lo..<hi])
    }

    /// NFR-SEC5: `<document name="…" pages="…" untrusted="true">…</document>` (M6.T02 places it before the user text).
    public func promptBlock(name: String) -> String {
        var attrs = "name=\"\(Self.escape(name))\""
        if let pages = pageCount ?? slideCount { attrs += " pages=\"\(pages)\"" }
        return "<document \(attrs) untrusted=\"true\">\n\(UntrustedText.neutralised(markdown))\n</document>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `units` as the `attachment.page_map_json` value.
    public var unitsJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? String(decoding: enc.encode(units), as: UTF8.self)) ?? "[]"
    }
}

/// Builds Markdown with a unit map (offsets in UTF-16, the way `NSString` / `Unit.start` count).
struct MarkdownBuilder {
    private(set) var text = ""
    private(set) var units: [ExtractedDocument.Unit] = []
    private var length = 0

    mutating func append(_ s: String) {
        text += s
        length += s.utf16.count
    }

    /// Appends one unit's body (preceded by a blank line when something came before).
    mutating func unit(_ kind: ExtractedDocument.UnitKind, index: Int, label: String? = nil, rows: Int? = nil,
                       _ body: String) {
        if length > 0 { append("\n\n") }
        let start = length
        append(body)
        units.append(.init(kind: kind, index: index, label: label, start: start, end: length, rows: rows))
    }

    func build(transcriptionPending: Bool = false) -> ExtractedDocument {
        ExtractedDocument(markdown: text, units: units, transcriptionPending: transcriptionPending)
    }
}
