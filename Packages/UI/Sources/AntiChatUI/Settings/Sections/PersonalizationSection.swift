// Settings → Personalization (M1.T22 step 4; settings-map §6; R-062), in the look of the Connections and Skills pages
// (owner 2026-11-16): no boxes, room between the parts, quiet rows. Top to bottom: "About you" and "How should
// AntiChat respond" (each hard-limited to 3,000 characters, with a counter); two rows with an icon tile — Style
// (Default, Professional, Friendly, Candid, Efficient, Quirky) and Memory (On / Paused / Off; M8.T03, behind
// ff.memory, for an on-disk database); the saved memories as a plain list (MemoryList: search once there are many,
// add, edit, delete with Undo); suggestions from the background review; and Advanced, closed: the four
// characteristics (Warmth, Enthusiasm, Headers & lists, Emoji: More / Default / Less) and memory's finer rows.
// `PersonalizationSync` feeds the values to the prompt's layer 3.
// The page sits in Settings' grouped form (SettingsDetail), whose sections draw a box around their rows; a section's
// header is drawn bare, so the whole page is the header of one empty section (as the page's title already is).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Defaults
import SwiftUI

struct PersonalizationSection: View {
    @Bindable var model: SettingsModel
    @State private var memory: MemorySettingsViewModel?
    /// Snapshots pin their own memories.
    @Environment(\.settingsMemoryModel) private var pinnedMemory
    @Default(.aboutYou) private var aboutYou
    @Default(.howToRespond) private var howToRespond
    @Default(.stylePreset) private var stylePreset
    @Default(.warmth) private var warmth
    @Default(.enthusiasm) private var enthusiasm
    @Default(.headersAndLists) private var headersAndLists
    @Default(.emoji) private var emoji

    init(model: SettingsModel, chats: ChatListService? = nil) {
        self.model = model
        let db = chats?.database
        let on = FeatureFlag.memory.isEnabled(.antichat) && db?.isInMemory == false
        _memory = State(initialValue: on ? db.map { MemorySettingsViewModel(database: $0) } : nil)
    }

    var body: some View {
        let memory = pinnedMemory ?? memory
        Section {} header: {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                VStack(alignment: .leading, spacing: Spacing.space4) {
                    BoundedTextArea(id: "aboutYou", placeholder: CopyKey("set.pers.aboutYou.placeholder"), text: $aboutYou)
                    BoundedTextArea(id: "howToRespond", placeholder: CopyKey("set.pers.howToRespond.placeholder"),
                                    text: $howToRespond)
                    Text(CopyKey("set.pers.note")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    PersonalizationRow(id: "stylePreset", symbol: "textformat", detail: CopyKey("set.pers.style.note")) {
                        QuietMenu(selection: $stylePreset, label: CopyKey("set.pers.style"), id: "settings.control.stylePreset",
                                  options: Personalization.StylePreset.allCases.map { ($0.rawValue, CopyKey("set.pers.style.\($0.rawValue)")) })
                    }
                    if let memory { MemoryModeRow(model: memory) }
                }
                if let memory {
                    MemoryList(model: memory).onAppear { memory.reload() }
                    MemorySuggestions(model: memory)
                }
                advanced(memory)
            }
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.space3)
        }
    }

    /// The page's Advanced group, closed until asked for: a quiet line with a chevron, as on Connections.
    @ViewBuilder private func advanced(_ memory: MemorySettingsViewModel?) -> some View {
        let open = model.advancedOpen.contains(.personalization)
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Divider()
            Button { model.setAdvanced(.personalization, !open) } label: {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "chevron.right").typeStyle(.caption).foregroundStyle(Color.textSecondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(CopyKey("set.cap.advanced")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: open ? "1" : "0"))
            .modifier(HighlightRow(id: "personalization.advanced"))
            .id("personalization.advanced")
            .probeID("settings.row.personalization.advanced")
            if open {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    AdvancedHeading("set.pers.characteristics")
                    LevelRow(id: "warmth", value: $warmth)
                    LevelRow(id: "enthusiasm", value: $enthusiasm)
                    LevelRow(id: "headersAndLists", value: $headersAndLists)
                    LevelRow(id: "emoji", value: $emoji)
                    if let memory {
                        AdvancedHeading("set.memory.mode").padding(.top, Spacing.space2)
                        MemoryAdvancedRows(model: memory)
                    }
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// The memory model the Personalization page shows instead of the chat database's (tests).
    @Entry var settingsMemoryModel: MemorySettingsViewModel? = nil
}

/// A row of the page in the directory look: an icon tile, the setting's name, one grey line, its control at the right.
struct PersonalizationRow<Control: View>: View {
    let id: String
    let symbol: String
    let detail: CopyKey
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.textPrimary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(SettingsRegistry.row(id)?.label ?? detail).typeStyle(.callout).fontWeight(.medium)
                    .foregroundStyle(Color.textPrimary).lineLimit(1)
                Text(detail).typeStyle(.subhead).foregroundStyle(Color.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.row.\(id).description")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, Spacing.space2)
        .id(id)
        .modifier(HighlightRow(id: id))
        .accessibilityElement(children: .contain)
        .probeID("settings.row.\(id)")
    }
}

/// A quiet pop-up: the chosen value and the menu's small chevron, no bezel. The menu lists every option, the chosen one ticked.
struct QuietMenu: View {
    @Binding var selection: String
    let label: CopyKey
    let id: String
    let options: [(value: String, name: CopyKey)]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.value) { o in Text(o.name).tag(o.value) }
            } label: { Text(label) }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Text(options.first { $0.value == selection }?.name ?? label).typeStyle(.callout).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(options.first { $0.value == selection }?.name ?? label))
        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
        .probeID(id)
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
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(SettingsRegistry.row(id)?.label ?? placeholder).typeStyle(.headline).foregroundStyle(Color.textPrimary)
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
            .padding(Spacing.space2)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
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
