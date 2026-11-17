// SourcesPanel (M7.T03 step 8; R-250 AC1; components.md §3 SourcesPanel; S-10): the "Sources" button under a reply
// that used the web opens the SidePanel with **every** fetched page of the reply: the cited ones first (in citation
// order), then the other fetched pages under `search.sources.more`. Each row: the page's own favicon, title, domain,
// date and the result snippet; a click opens the page in the browser. Rows carry `sourcesRow.<n>` (the UI test
// matches them with the pills' `citation.<n>`).
import AntiChatDesign
import AntiChatStorage
import SwiftUI

public struct SourcesContent: Equatable, Sendable {
    public var cited: [MessageProvenance.WebSourceRecord]
    public var more: [MessageProvenance.WebSourceRecord]

    /// Fetched sources only; `citedOrder` = the reply's pill order.
    public init(sources: [MessageProvenance.WebSourceRecord], citedOrder: [Int]) {
        // Each page once: a search can return the same page (or the same title on the same site) twice.
        var seenPages = Set<String>()
        let fetched = sources.filter(\.fetched).filter { s in
            let url = s.url.lowercased().split(separator: "#").first.map(String.init) ?? s.url
            let page = url.hasSuffix("/") ? String(url.dropLast()) : url
            let titled = CitationPill.siteKey(s) + "|" + s.title.lowercased()
            guard !seenPages.contains(page), !seenPages.contains(titled) else { return false }
            seenPages.insert(page); seenPages.insert(titled)
            return true
        }
        let byN = Dictionary(fetched.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        cited = citedOrder.compactMap { byN[$0] }
        let citedSet = Set(cited.map(\.n))
        more = fetched.filter { !citedSet.contains($0.n) }
    }

    public var all: [MessageProvenance.WebSourceRecord] { cited + more }

    /// Up to three pages for the Sources button's icons: different sites first.
    var faces: [MessageProvenance.WebSourceRecord] {
        var seen = Set<String>()
        let distinct = all.filter { seen.insert(CitationPill.siteKey($0)).inserted }
        return Array(distinct.prefix(3))
    }
}

struct SourcesPanel: View {
    let content: SourcesContent
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.space1) {
                ForEach(content.cited, id: \.n) { row($0) }
                if !content.more.isEmpty {
                    // "More" only divides the cited pages from the rest; a list with one kind has no heading.
                    if !content.cited.isEmpty {
                        Text(CopyKey("search.sources.more"))
                            .typeStyle(.footnote).fontWeight(.semibold)
                            .foregroundStyle(Color.textSecondary)
                            .padding(.top, Spacing.space3)
                            .padding(.horizontal, Spacing.space3)
                            .probeID("sourcesMore")
                    }
                    ForEach(content.more, id: \.n) { row($0) }
                }
            }
            .padding(Spacing.space3)
        }
        .accessibilityIdentifier("sourcesPanel")
    }

    private func row(_ s: MessageProvenance.WebSourceRecord) -> some View {
        Button {
            if let u = URL(string: s.url) { openURL(u) }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                HStack(spacing: Spacing.space2) {
                    SourceFavicon(data: s.faviconData, size: 16, site: s.site)
                    Text(verbatim: CitationPill.domain(s.site)).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    if let d = s.date { Text(verbatim: "· \(SourceFavicon.displayDate(d))").typeStyle(.footnote).foregroundStyle(Color.textTertiary) }
                }
                Text(verbatim: s.title).typeStyle(.callout).fontWeight(.medium).foregroundStyle(Color.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !s.snippet.isEmpty {
                    Text(verbatim: s.snippet).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(SourceRowStyle())
        .accessibilityIdentifier("sourcesRow.\(s.n)")
        .probeID("sourcesRow.\(s.n)")
    }
}

private struct SourceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SourceRow(configuration: configuration) }
    struct SourceRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Color.textPrimary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.05 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

/// The "Sources" button under a reply that used the web: up to three stacked favicons + `search.sources`.
struct SourcesButton: View {
    let content: SourcesContent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                HStack(spacing: 2) {
                    ForEach(Array(content.faces.enumerated()), id: \.offset) { _, s in
                        SourceFavicon(data: s.faviconData, size: 16, site: s.site)
                    }
                }
                Text(CopyKey("search.sources")).typeStyle(.footnote).fontWeight(.medium)
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.space3)
            .frame(height: 26)
            .background(Capsule().fill(Color.textPrimary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sourcesButton")
        .probeID("sourcesButton")
    }
}
