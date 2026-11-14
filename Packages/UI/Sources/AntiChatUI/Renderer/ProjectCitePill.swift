// M8.T05 step 2 (R-245 AC2): `[n]` citations of a retrieval-mode project reply become pills linking to the cited file
// at its page, only when n is one of the passages the reply was given (`provenance_json.project_sources`). Any other
// `[n]` is dropped and logged locally (the web-citation rule: zero pills without a resolved source). A click opens a
// PDF at the page (PDFPageSheet / the side panel), any other file in Quick Look.
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import Foundation
import SwiftUI

enum ProjectCitePill {
    static let scheme = "antichat-project"
    /// `[3]`, `[source 3]`, `[1, 2]` / `[1][2]` (each bracket on its own), not `[x](…)` Markdown links.
    static let pattern = try! NSRegularExpression(pattern: #"\[(?:source\s*)?(\d{1,2}(?:\s*,\s*\d{1,2})*)\](?!\()"#,
                                                  options: [.caseInsensitive])

    static func label(_ s: MessageProvenance.ProjectSource) -> String {
        guard let p = s.page else { return s.name }
        if Int(p) != nil { return CopyText(CopyKey("project.cite"), ["file": s.name, "page": p]).string }
        return "\(s.name), \(p)"
    }

    static func link(_ s: MessageProvenance.ProjectSource) -> String {
        let page = s.page.flatMap(Int.init) ?? 0
        return "[\(label(s))](\(scheme)://\(s.fileID)/\(page))"
    }

    /// The reply with valid `[n]` as links, unresolved ones removed.
    static func linkify(_ text: String, sources: [MessageProvenance.ProjectSource]) -> String {
        guard !sources.isEmpty else { return text }
        let byN = Dictionary(sources.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        let ns = text as NSString
        var out = text
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let ids = ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let range = Range(m.range, in: out)!
            let links = ids.compactMap { byN[$0] }.map(link)
            if links.count < ids.count {
                AppLog.log(.ui, .notice, "dropped project citation \(ids.filter { byN[$0] == nil }): not a passage of the reply")
            }
            out.replaceSubrange(range, with: links.isEmpty ? "" : "(" + links.joined(separator: " ") + ")")
        }
        return out.replacingOccurrences(of: " +([.,;:])", with: "$1", options: .regularExpression)
    }

    /// `antichat-project://<file>/<page>` → (file, page; 0 = no page).
    static func target(_ url: URL) -> (fileID: String, page: Int)? {
        guard url.scheme == scheme, let host = url.host(), let page = Int(url.lastPathComponent) else { return nil }
        return (host, page)
    }
}

/// M8.T05 step 3: `act.projectSearch` "Searched project files · {count} passages ▸"; expanded, the passages' files
/// and pages (each opens the file there).
struct ProjectSearchLine: View {
    let sources: [MessageProvenance.ProjectSource]
    var open: (String, Int) -> Void = { _, _ in }
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color.textSecondary)
                    Text(CopyText(CopyKey("act.projectSearch"), ["count": "\(sources.count)"]))
                        .typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(Color.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .probeID("projectSearchLine")
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    ForEach(sources, id: \.n) { s in
                        Button { open(s.fileID, s.page.flatMap(Int.init) ?? 0) } label: {
                            Text(verbatim: "[\(s.n)] \(ProjectCitePill.label(s))").typeStyle(.footnote)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, Spacing.space5)
            }
        }
    }
}
