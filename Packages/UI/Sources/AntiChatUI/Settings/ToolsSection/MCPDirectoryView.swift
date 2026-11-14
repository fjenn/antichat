// M7.T06 step 8 (R-081 AC4; P-files-tools-12: ported in design from Osaurus Views/Settings/MCPProviderDirectoryView,
// no code copied): "Popular connections" with a search field and category chips; a card's Add pre-fills the add form
// with its URL and auth kind. OAuth entries need M7.T07's sign-in; CIMD-only entries are hidden until published.
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct MCPDirectoryView: View {
    let entries: [MCPCuratedEntry]
    var onPick: (MCPCuratedEntry) -> Void
    @State private var query = ""
    @State private var category: String?

    var categories: [String] { Array(Set(entries.map(\.category))).sorted() }

    var shown: [MCPCuratedEntry] {
        entries.filter { e in
            (category == nil || e.category == category)
                && (query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || e.tagline.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CopyKey("conn.curated.title")).font(.headline)
            // VQ: a search field with its prompt inside, not a form label floating to its left.
            TextField(text: $query, prompt: Text(CopyKey("conn.search"))) { Text(CopyKey("conn.search")) }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip(nil, Text(CopyKey("conn.all")))
                    ForEach(categories, id: \.self) { c in chip(c, Text(verbatim: c)) }
                }
            }
            .accessibilityLabel(Text(CopyKey("conn.all")))  // M9.T03: the chip row is a named scroll area
            // VQ (S-21 Tools, M10): two cards per row; three 200 pt cards cut "Hugging Face" to "Hugging…".
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(shown) { e in card(e) }
            }
            // M9.T03: a lazy grid is an unnamed "Other" to accessibility; the cards sit in a named group.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(CopyKey("conn.curated.title")))
        }
        .accessibilityElement(children: .contain)  // keeps mcpDirectory.add.<id> (Q-015 catch-up)
        .probeID("mcpDirectory")
    }

    private func chip(_ c: String?, _ label: Text) -> some View {
        // VQ (S-21 Tools, M10): callout-size pills (the caption ones were tiny); the chosen one is filled.
        Button { category = c } label: { label.typeStyle(.callout).padding(.horizontal, 6).padding(.vertical, 2) }
            .buttonStyle(.bordered).controlSize(.regular)
            .tint(category == c ? .accentColor : .secondary)
            .accessibilityAddTraits(category == c ? .isSelected : [])
            .accessibilityIdentifier("mcpDirectory.chip.\(c ?? "all")")
    }

    private func card(_ e: MCPCuratedEntry) -> some View {
        // M9.T03: the tagline runs the card's full width under the name row. Beside the Connect button it got a
        // ~65 pt column and was cut to "Browse re…" (and failed the contrast audit as a clipped two-line sliver).
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: e.icon).frame(width: 20)
                    .accessibilityHidden(true)  // decorative; its symbol name was its label (M9.T03 audit)
                Text(verbatim: e.name).font(.body).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                // VQ: sign-in entries connect too (M7.T07 OAuth is in; the add form opens on "Sign in with the app").
                Button { onPick(e) } label: { Text(CopyKey("conn.connect")) }
                    .probeID("mcpDirectory.add.\(e.id)")
            }
            Text(verbatim: e.tagline).typeStyle(.footnote).foregroundStyle(Color.textPrimary)  // M9.T03: wraps; size sets the hierarchy
                .accessibilityIdentifier("mcpDirectory.tagline.\(e.id)")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surfaceSunken))  // M9.T03: a token, lighter than secondary at 8%
    }
}
