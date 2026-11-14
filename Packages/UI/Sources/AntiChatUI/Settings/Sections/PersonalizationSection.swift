// Settings → Personalization (M1.T22 step 4; settings-map §6; R-062): "About you" and "How should AntiChat
// respond" (each hard-limited to 3,000 characters, with a counter), the Style preset (Default, Professional,
// Friendly, Candid, Efficient, Quirky) and four characteristics (Warmth, Enthusiasm, Headers & lists, Emoji:
// More / Default / Less). `PersonalizationSync` feeds the values to the prompt's layer 3 for every new turn.
// M8.T03: the Memory rows (MemorySettingsSection) for an on-disk database, behind ff.memory.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Defaults
import SwiftUI

struct PersonalizationSection: View {
    var chats: ChatListService? = nil
    @Default(.aboutYou) private var aboutYou
    @Default(.howToRespond) private var howToRespond
    @Default(.stylePreset) private var stylePreset
    @Default(.warmth) private var warmth
    @Default(.enthusiasm) private var enthusiasm
    @Default(.headersAndLists) private var headersAndLists
    @Default(.emoji) private var emoji

    var body: some View {
        if FeatureFlag.memory.isEnabled(.antichat), let db = chats?.database, !db.isInMemory {
            MemorySettingsHost(database: db)
        }
        Section {
            BoundedTextArea(id: "aboutYou", placeholder: CopyKey("set.pers.aboutYou.placeholder"), text: $aboutYou)
            BoundedTextArea(id: "howToRespond", placeholder: CopyKey("set.pers.howToRespond.placeholder"),
                            text: $howToRespond)
        } footer: {
            Text(CopyKey("set.pers.note")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
        }
        Section {
            SettingsItem("stylePreset") {
                Picker(selection: $stylePreset) {
                    ForEach(Personalization.StylePreset.allCases, id: \.self) { p in
                        Text(CopyKey("set.pers.style.\(p.rawValue)")).tag(p.rawValue)
                    }
                } label: { Text(CopyKey("set.pers.style")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.stylePreset")
            }
        }
        Section {
            LevelRow(id: "warmth", value: $warmth)
            LevelRow(id: "enthusiasm", value: $enthusiasm)
            LevelRow(id: "headersAndLists", value: $headersAndLists)
            LevelRow(id: "emoji", value: $emoji)
        } header: {
            Text(CopyKey("set.pers.characteristics")).typeStyle(.subhead)
        }
    }
}

/// More / Default / Less for one characteristic.
private struct LevelRow: View {
    let id: String
    @Binding var value: String

    var body: some View {
        SettingsItem(id) {
            Picker(selection: $value) {
                ForEach(Personalization.Level.allCases, id: \.self) { l in
                    Text(CopyKey("set.pers.level.\(l.rawValue)")).tag(l.rawValue)
                }
            } label: { Text(SettingsRegistry.row(id)?.label ?? CopyKey("set.pers.characteristics")) }
                .pickerStyle(.segmented).accentFilledSegments()
                .fixedSize()
                .probeID("settings.control.\(id)")
        }
    }
}

/// A text area that refuses the 3,001st character (R-062 AC1) and shows "{count}/3000".
struct BoundedTextArea: View {
    let id: String
    let placeholder: CopyKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text(SettingsRegistry.row(id)?.label ?? placeholder).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                Spacer()
                Text(CopyText(CopyKey("set.pers.counter"), ["count": "\(text.count)", "max": "\(Personalization.maxChars)"]))
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(text.count >= Personalization.maxChars ? Color.textPrimary : Color.textTertiary)
                    .probeID("settings.counter.\(id)")
                    .accessibilityValue(Text(verbatim: "\(text.count)"))
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { text }, set: { text = Personalization.clamp($0) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72, maxHeight: 140)
                    // Q-015 r5 (AT-223 inventory): the field had no name of its own (the title and the placeholder are
                    // separate texts), so VoiceOver read an unlabeled text area.
                    .accessibilityLabel(Text(SettingsRegistry.row(id)?.label ?? placeholder))
                    .probeID("settings.control.\(id)")
                if text.isEmpty {
                    Text(placeholder)
                        .typeStyle(.body)
                        .foregroundStyle(Color.textTertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(Spacing.space1)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .padding(.vertical, Spacing.space1)
        .id(id)
        .modifier(HighlightRow(id: id))
        .accessibilityElement(children: .contain)  // keeps settings.control/counter.<id> on the field (Q-015)
        .probeID("settings.row.\(id)")
    }
}

/// The reveal highlight for rows that are not a `SettingsItem`.
struct HighlightRow: ViewModifier {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let id: String
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                // VQ: 14 % of the accent vanished on the dark grouped background; dark gets a stronger wash.
                .fill(highlight == id ? accentPreset.color.opacity(scheme == .dark ? 0.30 : 0.14) : .clear)
                .padding(-Spacing.space1)
        )
    }
}

/// Keeps one MemorySettingsViewModel for the page's lifetime.
private struct MemorySettingsHost: View {
    @State private var model: MemorySettingsViewModel
    init(database: AppDatabase) { _model = State(initialValue: MemorySettingsViewModel(database: database)) }
    var body: some View { MemorySettingsSection(model: model).onAppear { model.reload() } }
}
