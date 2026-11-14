// M6.T04 step 1 (R-271 AC1): a PDF page needs OCR iff its text layer has fewer than 20 non-blank characters (after
// trimming whitespace and newlines). Images always get OCR (step 3), outside this rule.
import Foundation
import PDFKit

public enum ScanDetector {
    /// The rule's threshold: `count < minChars` → OCR.
    public static let minChars = 20

    public static func needsOCR(_ text: String?) -> Bool {
        (text?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) < minChars
    }

    /// 1-based numbers of the pages of `pdf` that need OCR.
    public static func scanPages(_ pdf: PDFDocument) -> [Int] {
        (0..<pdf.pageCount).filter { needsOCR(pdf.page(at: $0)?.string) }.map { $0 + 1 }
    }

    /// 1-based numbers of the page units of an extracted PDF whose text needs OCR.
    public static func scanPages(_ doc: ExtractedDocument) -> [Int] {
        doc.units.filter { $0.kind == .page && needsOCR(doc.text(of: $0)) }.map(\.index)
    }
}

extension ExtractedDocument {
    /// The same document with the text of some page units replaced (OCR results), unit map rebuilt.
    public func replacingPages(_ texts: [Int: String]) -> ExtractedDocument {
        guard !texts.isEmpty else { return self }
        var md = MarkdownBuilder()
        for u in units {
            let body = u.kind == .page ? (texts[u.index] ?? text(of: u)) : text(of: u)
            md.unit(u.kind, index: u.index, label: u.label, rows: u.rows, body)
        }
        var out = md.build(transcriptionPending: transcriptionPending)
        out.tokenCount = nil
        return out
    }
}
