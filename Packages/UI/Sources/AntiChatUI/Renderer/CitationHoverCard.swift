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
                            SourceFavicon(data: s.faviconData, size: 14, site: s.site)
                            Text(verbatim: CitationPill.domain(s.site)).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                            if let d = s.date { Text(verbatim: "· \(SourceFavicon.displayDate(d))").typeStyle(.footnote).foregroundStyle(Color.textTertiary) }
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
    /// The page's site: without a stored favicon its initial shows instead of a generic globe.
    var site: String = ""

    /// "2026-11-12" as people read it: "Today", "Yesterday", "Nov 12" (the year when it is not this one). Anything
    /// that is not an ISO day stays as it is.
    static func displayDate(_ iso: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(iso.prefix(10))) else { return iso }
        if calendar.isDate(d, inSameDayAs: now) || calendar.isDateInYesterday(d) {
            let r = DateFormatter()
            r.dateStyle = .medium
            r.timeStyle = .none
            r.doesRelativeDateFormatting = true
            return r.string(from: d)
        }
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        return d.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    static let tints: [AccentPreset] = [.blue, .green, .orange, .purple, .pink, .red]

    /// The same site always gets the same tint (a stable hash of its name, not `hashValue`, which changes per launch).
    static func tint(_ site: String) -> Color {
        let sum = CitationPill.domain(site).lowercased().unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return tints[Int(sum % UInt32(tints.count))].color
    }

    var body: some View {
        let initial = CitationPill.siteName(site).first.map { String($0).uppercased() }
        if let img = CitationPill.image(data) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if let initial {
            // A monogram on a tinted circle, the tint picked by the site's name: three sites without an icon read as
            // three sites, not as the same grey letter three times.
            let tint = Self.tint(site)
            Text(verbatim: initial).font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(0.18)))
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.8)).foregroundStyle(Color.textTertiary)
                .frame(width: size, height: size)
        }
    }
}
