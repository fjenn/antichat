// M6.T02 step 5 (R-270 AC4): "(p. N)" / "(pp. N–M)" in a finished reply become page links rendered as pills, only
// when N is a page of an attached document the reply used (a whole file: 1…pages; excerpts: among the retrieved
// pages). Anything else is dropped from the text and logged locally (the web-citation rule). A click opens the
// document at that page (`PDFPageSheet`, PDFView.go(to:)).
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import Foundation
import PDFKit
import MarkdownView
import SwiftUI

enum PageCitePill {
    static let scheme = "antichat-page"
    static let pattern = try! NSRegularExpression(pattern: #"\((pp?)\.\s?(\d{1,4})(?:\s?[–-]\s?(\d{1,4}))?\)"#)

    /// The PDF attachments page `page` can belong to (M6 review #12: only PDFs, whose pages the sheet can open; a
    /// deck's slide count is not a page range).
    static func owners(of page: Int, in uses: [MessageProvenance.FileUse]) -> [String] {
        uses.filter { $0.pdf != false }.compactMap { u in
            if u.mode == ExcerptPolicy.excerpt.rawValue { return u.pages.contains(String(page)) ? u.attachmentID : nil }
            if let n = u.pageCount, (1...max(1, n)).contains(page) { return u.attachmentID }
            return nil
        }
    }

    /// The attachment a page belongs to: exactly one match (nil = invalid, or ambiguous between several files).
    static func owner(of page: Int, in uses: [MessageProvenance.FileUse]) -> String? {
        let o = owners(of: page, in: uses)
        return o.count == 1 ? o[0] : nil
    }

    /// The reply text with valid citations as `[p. N](antichat-page://<attachment>/<N>)` links; invalid ones removed.
    static func linkify(_ text: String, uses: [MessageProvenance.FileUse]) -> String {
        guard !uses.isEmpty else { return text }
        let ns = text as NSString
        var out = text
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let first = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let last = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil
            let range = Range(m.range, in: out)!
            let candidates = owners(of: first, in: uses)
            if candidates.count == 1, let att = candidates.first,
               last.map({ owners(of: $0, in: uses).contains(att) }) ?? true {
                let label = CopyText(CopyKey("files.pageCite"), ["page": last.map { "\(first)–\($0)" } ?? "\(first)"]).string
                // VQ-M10 round 65 (S-14): the citation renders as an inline pill (PageCitePillView), without the
                // parentheses around it; the range end and the file name ride along for the pill's label and help.
                out.replaceSubrange(range, with: "[\(label)](\(link(att, first, last: last, uses: uses)))")
            } else if candidates.count > 1 {
                continue  // a page of several attached files: kept as text, no link to a guess
            } else {
                AppLog.log(.ui, .notice, "dropped page citation p. \(first): not a page of the reply's documents")
                out.replaceSubrange(range, with: "")
            }
        }
        return out.replacingOccurrences(of: " +([.,;:])", with: "$1", options: .regularExpression)
    }

    /// `antichat-page://<attachment>/<page>[?to=<last>&name=<file>]`.
    static func link(_ att: String, _ first: Int, last: Int?, uses: [MessageProvenance.FileUse]) -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = att
        c.path = "/\(first)"
        var query = [URLQueryItem]()
        if let last { query.append(URLQueryItem(name: "to", value: "\(last)")) }
        if let name = uses.first(where: { $0.attachmentID == att })?.name { query.append(URLQueryItem(name: "name", value: name)) }
        c.queryItems = query.isEmpty ? nil : query
        // Markdown link destinations end at a space or an unbalanced ")": both are percent-encoded.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return c.string ?? "\(scheme)://\(att)/\(first)"
    }

    /// The pill's label ("p. 3" / "p. 3–5") and file name from a page link.
    static func pill(_ url: URL) -> (label: String, name: String?)? {
        guard let t = target(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let to = items.first { $0.name == "to" }?.value
        let label = CopyText(CopyKey("files.pageCite"), ["page": to.map { "\(t.page)–\($0)" } ?? "\(t.page)"]).string
        return (label, items.first { $0.name == "name" }?.value)
    }

    /// `antichat-page://<attachment>/<page>` → (attachment, page).
    static func target(_ url: URL) -> (attachmentID: String, page: Int)? {
        guard url.scheme == scheme, let host = url.host(), let page = Int(url.lastPathComponent) else { return nil }
        return (host, page)
    }
}

/// The document at a cited page (a sheet over the chat).
struct PDFPageSheet: View {
    struct Target: Identifiable, Equatable {
        let url: URL; let page: Int; var name: String? = nil
        var id: String { "\(url.path)#\(page)" }
    }
    let target: Target
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: target.url.lastPathComponent).typeStyle(.headline)
                Text(CopyText(CopyKey("files.pageCite"), ["page": "\(target.page)"])).typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button(action: onDone) { Text(CopyKey("composer.pasteCard.done")) }.keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.space3)
            PDFPageView(url: target.url, page: target.page)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 760)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("pdfPageSheet")
    }
}

private struct PDFPageView: NSViewRepresentable {
    let url: URL
    let page: Int
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        if let p = v.document?.page(at: max(0, page - 1)) { v.go(to: p) }
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}

/// VQ-M10 round 65 (S-14): MarkdownView renders every `antichat-page://` link as an inline pill (a document glyph and
/// "p. 3", the file in its tooltip), like the web citation pills; a click opens the document at that page (the
/// message's `openURL` handler → `openPage`).
struct PageCitePillRenderer: MarkdownLinkRenderer {
    func makeBody(configuration: MarkdownLinkRendererConfiguration) -> some View {
        PageCitePillView(url: configuration.url)
    }
}

struct PageCitePillView: View {
    let url: URL
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        if let pill = PageCitePill.pill(url) {
            let spoken = pill.name.map { "\($0), \(pill.label)" } ?? pill.label
            Button { openURL(url) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").font(.system(size: 10, weight: .medium))
                    Text(verbatim: pill.label)
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(hovering ? Color.textPrimary : Color.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.textPrimary.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(spoken)
            .accessibilityLabel(Text(verbatim: spoken))
            .accessibilityIdentifier("pageCite")
            .fixedSize()
        }
    }
}
