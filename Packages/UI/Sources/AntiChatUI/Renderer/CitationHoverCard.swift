// CitationHoverCard (M7.T03 step 7; R-250; components.md §3): what a CitationPill shows on hover — per cited source
// the page's own favicon (read from the fetched page, ≤ 16 KB, never a favicon service), its domain, date and title.
// A click opens the page in the browser. SourceFavicon is shared with the Sources panel.
import AntiChatDesign
import AppKit
import SwiftUI

/// The hover card: per cited source the page's own favicon, its title and domain (and date when known).
struct CitationHoverCard: View {
    let sources: [WebSourceRecord]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(sources, id: \.n) { s in
                Button {
                    if let u = URL(string: s.url) { openURL(u) }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        HStack(spacing: Spacing.space2) {
                            SourceFavicon(data: s.faviconData, size: 14)
                            Text(verbatim: CitationPill.domain(s.site)).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                            if let d = s.date { Text(verbatim: "· \(d)").typeStyle(.footnote).foregroundStyle(Color.textTertiary) }
                        }
                        Text(verbatim: s.title).typeStyle(.callout).fontWeight(.medium).foregroundStyle(Color.textPrimary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .probeID("citationCard.\(s.n)")
            }
        }
        .padding(Spacing.space3)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("citationHoverCard")
    }
}

/// The page's own icon, or a globe when none was read.
struct SourceFavicon: View {
    let data: String?
    var size: CGFloat = 16

    var body: some View {
        if let img = CitationPill.image(data) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.8)).foregroundStyle(Color.textTertiary)
                .frame(width: size, height: size)
        }
    }
}
