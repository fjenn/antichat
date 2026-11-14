// M10.T06 (R-217 AC1/AC2): Help › Legal and About & Help › Legal — the bundled pages with "Version {v} · {date}",
// readable offline. "View latest online" opens the site page (the browser, nothing fetched in the app).
import AntiChatDesign
import AntiChatPlatform
import AppKit
import SwiftUI

struct LegalSheet: View {
    let onClose: () -> Void
    private let pages = BundledDocument.legalPages()
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("legal.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            HStack(alignment: .top, spacing: Spacing.space3) {
                List(pages, selection: $selection) { page in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: page.title)
                        Text(CopyText(CopyKey("legal.version"), ["version": page.version ?? "—", "date": page.updated ?? "—"]))
                            .typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    }
                    .tag(page.id)
                    .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                    .probeID("legal.row.\(page.id)")
                }
                .frame(width: 220)
                ScrollView {
                    Text((pages.first { $0.id == selection } ?? pages.first)?.attributed ?? AttributedString(""))
                        .typeStyle(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.space3)
                        .accessibilityIdentifier("legal.body")
                }
            }
            .frame(height: 420)
            HStack {
                Button {
                    let slug = selection ?? pages.first?.id ?? "terms"
                    let path = slug == "acceptable-use" ? "/acceptable-use/" : "/legal/\(slug)/"
                    if let url = SiteLinks.url(path) { SiteLinks.open(url) }
                } label: { Text(CopyKey("legal.viewOnline")) }
                    .accessibilityIdentifier("legal.viewOnline")
                Spacer()
                Button(action: onClose) { Text(CopyKey("systemReport.close")) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 760)
        .onAppear { selection = selection ?? pages.first?.id }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("legal.sheet")
    }
}
