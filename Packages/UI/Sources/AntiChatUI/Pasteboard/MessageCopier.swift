// Copy a reply (M1.T10 step 5; R-005 AC5): one pasteboard item with three flavours, so the paste target picks
// the richest it understands:
//   public.utf8-plain-text = the Markdown source (exactly what was stored),
//   public.html            = the rendered rich text (swift-markdown's HTMLFormatter, the renderer's parser),
//   public.rtf             = the same HTML converted by AppKit (pastes formatted into TextEdit, Pages, Mail).
// Local only: the HTML has no external resources, so the AppKit import never touches the network.
import AppKit
import Markdown

@MainActor
enum MessageCopier {
    /// The HTML fragment for `markdown`, wrapped in a minimal UTF-8 document.
    static func html(_ markdown: String) -> String {
        let body = HTMLFormatter.format(Document(parsing: markdown, options: [.disableSmartOpts]))
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
    }

    /// RTF data for `html` (nil if AppKit cannot convert it; the plain and HTML flavours are still written).
    static func rtf(html: String) -> Data? {
        guard let data = html.data(using: .utf8),
              let attributed = NSAttributedString(
                html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return nil }
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Writes a reply's Markdown source and its rendered rich text to `pasteboard`.
    static func copy(markdown: String, to pasteboard: NSPasteboard = .general) {
        let html = html(markdown)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setString(html, forType: .html)
        if let rtf = rtf(html: html) { item.setData(rtf, forType: .rtf) }
        pasteboard.writeObjects([item])
    }

    /// A user message: plain text only (what the user typed).
    static func copy(plain text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// The pasteboard the renderer's Copy buttons write to (default: the general pasteboard). Tests hand each host its
// own named pasteboard, so parallel tests (and other processes) never overwrite what a test reads back.
import SwiftUI

private struct PasteboardKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: NSPasteboard = .general
}

extension EnvironmentValues {
    var pasteboard: NSPasteboard {
        get { self[PasteboardKey.self] }
        set { self[PasteboardKey.self] = newValue }
    }
}
