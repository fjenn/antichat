// SettingsSidebar (M1.T22 step 1; components §6: 13 sections + search field; states selected · search results).
// System-Settings look: the search field on top, then the sections in settings-map order; while a query is typed
// the list shows the matching rows (label + section), and choosing one opens its section at that row.
import AntiChatDesign
import SwiftUI

struct SettingsSidebar: View {
    @Bindable var model: SettingsModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: Spacing.space2) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(SettingsSection.allCases, id: \.self) { section in
                            SettingsNavButton(symbol: section.symbol, title: section.title.string(), subtitle: nil,
                                              selected: model.selection == section,
                                              id: "settings.nav.\(section.rawValue)") { model.open(section) }
                        }
                    } else {
                        let results = model.results
                        if results.isEmpty {
                            Text(CopyText(CopyKey("set.search.empty"), ["query": model.query]))
                                .typeStyle(.footnote)
                                .foregroundStyle(Color.textSecondary)
                                .padding(Spacing.space2)
                                .probeID("settings.search.empty")
                        }
                        ForEach(results) { row in
                            SettingsNavButton(symbol: row.section.symbol, title: row.label.string(),
                                              subtitle: row.section.title.string(), selected: false,
                                              id: "settings.result.\(row.id)") { model.open(row.section, row: row.id) }
                        }
                    }
                }
                .padding(.horizontal, Spacing.space2)
            }
        }
        .padding(.top, Spacing.space2)
        .background(Color.surfaceSidebar)
        .accessibilityElement(children: .contain)  // keeps settings.search on the field (Q-015 catch-up)
        .probeID("settings.sidebar")
    }

    private var searchField: some View {
        HStack(spacing: Spacing.space1) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.textSecondary).accessibilityHidden(true)
            TextField(text: $model.query) { Text(CopyKey("set.search")) }
                .textFieldStyle(.plain)
                .typeStyle(.callout)
                .focused($searchFocused)
                // Keyboard-only (NFR-A3, Q-015 r6): Return opens the best match, as clicking it does; without it a
                // result was reachable only by Tab with Full Keyboard Access on.
                .onSubmit { if let first = model.results.first { model.open(first.section, row: first.id) } }
                .probeID("settings.search")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CopyKey("a11y.dismiss")))
            }
        }
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, 6)
        .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .padding(.horizontal, Spacing.space2)
        .background {  // ⌘F in Settings focuses its search (System Settings does the same); the window's own
            // key equivalent, so it answers before the main menu's Find in chat.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("settings.search.focusShortcut")
                .hidden()  // a key equivalent only, as OnboardingFlow's ⌘[
        }
    }
}

/// One sidebar entry (section or search result).
struct SettingsNavButton: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let symbol: String
    let title: String
    let subtitle: String?
    let selected: Bool
    let id: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.textOnAccent : Color.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .typeStyle(.callout)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.textOnAccent : Color.textPrimary)
                    if let subtitle {
                        Text(verbatim: subtitle).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.space2)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? accentPreset.color : (hovering ? Color.surfaceHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
