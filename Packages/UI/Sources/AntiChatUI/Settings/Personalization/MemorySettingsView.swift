// M8.T03 step 3 + 7 (R-060 AC2/AC3, R-246; S-21 §6, settings-map §6): Settings → Personalization → Memory, in the
// page's directory look (owner 2026-11-16). On the page: the Memory row (On / Paused / Off), the saved memories as a
// plain list (MemoryList: what was remembered, then topic · date · who saved it; a search field once there are many,
// + to add one, ⋯ to edit or delete, Undo after a delete) and Suggestions (cards for what the background review
// was unsure about: [Save] / [Dismiss]; what it is certain of it saves itself). Under Advanced (MemoryAdvancedRows):
// Include sensitive topics (On), Keep memory up to date automatically, Reset memory (typed RESET).
import AntiChatDesign
import AntiChatKnowledge
import AntiChatStorage
import Defaults
import SwiftUI

/// Memory On / Paused / Off, as a row with an icon tile.
struct MemoryModeRow: View {
    @Bindable var model: MemorySettingsViewModel

    var body: some View {
        PersonalizationRow(id: "memoryMode", symbol: "brain", detail: CopyKey("set.memory.note")) {
            // The menu explains each choice; the row shows the short word.
            QuietMenu(selection: Binding(get: { model.mode.rawValue }, set: { model.mode = MemoryPolicy.Mode(rawValue: $0) ?? .on }),
                      label: CopyKey("set.memory.mode"), id: "settings.control.memoryMode",
                      options: [("on", CopyKey("set.memory.on")), ("paused", CopyKey("set.memory.paused")), ("off", CopyKey("set.memory.off"))])
        }
    }
}

/// "Saved memories": every memory on this Mac as one quiet row.
struct MemoryList: View {
    @Bindable var model: MemorySettingsViewModel
    @State private var editing: String?
    @State private var draft = ""
    @State private var adding = false
    @State private var newTopic = ""
    @State private var newText = ""

    /// The search field appears once the list is longer than this.
    static let searchFrom = 8

    static func originKey(_ o: MemoryOrigin) -> CopyKey {
        switch o {
        case .user: CopyKey("memory.origin.user")
        case .tool: CopyKey("memory.origin.tool")
        case .review: CopyKey("memory.origin.review")
        case .import: CopyKey("memory.origin.import")
        }
    }

    /// The grey line of a row: topic · date · who saved it.
    static func detail(_ e: MemoryEntry) -> String {
        [e.topic.name, e.item.updatedAt.formatted(date: .abbreviated, time: .omitted), originKey(e.item.origin).string()]
            .joined(separator: " · ")
    }

    private var entries: [MemoryEntry] { model.groups.flatMap(\.entries) }
    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(spacing: Spacing.space3) {
                DirectorySectionTitle(title: Text(CopyKey("set.memory.saved")))
                Spacer(minLength: Spacing.space3)
                if model.count > Self.searchFrom || searching {
                    SearchField(text: $model.query, prompt: CopyKey("memory.browser.search"), id: "memory.search").labelsHidden().frame(maxWidth: 220)
                }
                DirectoryGlyphButton(symbol: "plus", label: CopyKey("memory.add").string(), id: "memory.add") { adding.toggle() }
            }
            if adding { addForm }
            if entries.isEmpty {
                Text(searching ? CopyText(CopyKey("search.empty"), ["query": model.query]) : CopyText(CopyKey("memory.browser.empty")))
                    .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .probeID("memory.empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries, id: \.item.id) { e in row(e) }
                }
            }
            if model.lastDeletedEvent != nil {
                Button { try? model.undoDelete() } label: { Text(CopyKey("toast.memoryDeleted")) }
                    .buttonStyle(.link)
                    .typeStyle(.callout)
                    .probeID("memory.undoDelete")
            }
        }
        .id("manageMemories")
        .modifier(HighlightRow(id: "manageMemories"))
        .accessibilityElement(children: .contain)
        .probeID("settings.row.manageMemories")
    }

    private var addForm: some View {
        HStack(spacing: Spacing.space2) {
            QuietField(text: $newTopic, prompt: CopyKey("memory.add.topic"), id: "memory.add.topic").frame(width: 130)
            QuietField(text: $newText, prompt: CopyKey("memory.add.text"), id: "memory.add.text")
            Button {
                try? model.add(topic: newTopic.isEmpty ? "General" : newTopic, text: newText)
                newTopic = ""; newText = ""; adding = false
            } label: { Text(CopyKey("memory.editor.save")) }
                .accessibilityIdentifier("memory.editor.save")
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private func row(_ e: MemoryEntry) -> some View {
        if editing == e.item.id {
            HStack(spacing: Spacing.space2) {
                QuietField(text: $draft, prompt: CopyKey("memory.add.text"), id: "memory.editor.text")
                Button { editing = nil } label: { Text(CopyKey("memory.editor.cancel")) }
                    .accessibilityIdentifier("memory.editor.cancel")
                Button { try? model.edit(e.item.id, text: draft); editing = nil } label: { Text(CopyKey("memory.editor.save")) }
                    .accessibilityIdentifier("memory.editor.save")
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft.count > MemoryStore.maxText)
            }
            .padding(.vertical, Spacing.space2)
        } else {
            MemoryRow(entry: e, onEdit: { draft = e.item.text; editing = e.item.id }, onDelete: { try? model.delete(e.item.id) })
        }
    }
}

/// One saved memory: what was remembered, one grey line, ⋯ (Edit, Delete).
private struct MemoryRow: View {
    let entry: MemoryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.item.text).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: MemoryList.detail(entry)).typeStyle(.subhead).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DirectoryMenu(label: "\(CopyKey("chat.more").string()), \(entry.item.text)") { actions }
                .probeID("memory.menu.\(entry.item.id)")
        }
        .padding(.vertical, Spacing.space2)
        // The text lines up with the section's title; the hover background reaches a little past it.
        .background {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(hovering ? Color.surfaceHover : Color.clear)
                .padding(.horizontal, -directoryRowInset)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .probeID("memory.row.\(entry.item.id)")
    }

    @ViewBuilder private var actions: some View {
        Button(action: onEdit) { Text(CopyKey("memory.edit")) }
            .accessibilityIdentifier("memory.edit")
        Button(role: .destructive, action: onDelete) { Text(CopyKey("memory.delete")) }
            .accessibilityIdentifier("memory.delete.\(entry.item.id)")
    }
}

/// A one-line text field in the search field's look (no border, a soft fill).
private struct QuietField: View {
    @Binding var text: String
    let prompt: CopyKey
    let id: String

    var body: some View {
        TextField(text: $text, prompt: Text(prompt)) { Text(prompt) }
            .textFieldStyle(.plain)
            .labelsHidden()
            .typeStyle(.callout)
            .padding(.horizontal, Spacing.space3)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken))
            .probeID(id)
    }
}

/// Suggestions from the background review (shown only while there are any): [Dismiss] / [Save] each.
struct MemorySuggestions: View {
    @Bindable var model: MemorySettingsViewModel

    var body: some View {
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                DirectorySectionTitle(title: Text(CopyKey("set.memory.suggestions")))
                ForEach(model.suggestions) { s in
                    MemorySuggestionCard(id: s.id, text: s.text, onDismiss: { try? model.dismissSuggestion(s.id) },
                                         onSave: { try? model.saveSuggestion(s.id) })
                }
            }
            .probeAnchor("memory.suggestions")
        }
    }
}

/// Memory's rows under the page's Advanced group: sensitive topics, suggestions, reset.
struct MemoryAdvancedRows: View {
    @Bindable var model: MemorySettingsViewModel
    @Default(.memoryIncludeSensitive) private var includeSensitive
    @Default(.memoryReviewEnabled) private var reviewEnabled
    @State private var resetting = false

    var body: some View {
        SettingsItem("memoryIncludeSensitive", description: CopyKey("set.memory.sensitive.note")) {
            Toggle(isOn: $includeSensitive) { Text(CopyKey("set.memory.sensitive")) }
                .toggleStyle(.accessibleSwitch).labelsHidden()
                .probeID("settings.control.memoryIncludeSensitive")
        }
        // What happens and when is the row's note.
        SettingsItem("memoryReviewEnabled", description: CopyKey("set.memory.suggest.note")) {
            Toggle(isOn: $reviewEnabled) { Text(CopyKey("set.memory.suggest")) }
                .toggleStyle(.accessibleSwitch).labelsHidden()
                .probeID("settings.control.memoryReviewEnabled")
        }
        // VQ: with nothing saved the row says so instead of showing a faint disabled button.
        SettingsItem("resetMemory", description: model.count == 0 ? CopyKey("set.memory.reset.empty") : nil) {
            if model.count > 0 {
                Button(role: .destructive) { resetting = true } label: {
                    Text(CopyKey("set.memory.reset.button")).foregroundStyle(Color.danger)
                }
                .probeID("settings.control.resetMemory")
                .sheet(isPresented: $resetting) {
                    MemoryResetSheet(count: model.count, onReset: { typed in try? model.reset(typed: typed); resetting = false },
                                     onCancel: { resetting = false })
                }
            }
        }
    }
}

struct MemoryResetSheet: View {
    let count: Int
    let onReset: (String) -> Void
    let onCancel: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("set.memory.reset")).typeStyle(.title3)
            Text(CopyText(CopyKey("memory.reset.body"), ["count": "\(count)"])).typeStyle(.callout)
                .foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $typed).textFieldStyle(.roundedBorder).probeID("memory.reset.field")
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("memory.reset.cancel")) }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) { onReset(typed) } label: { Text(CopyKey("memory.reset.cta")) }
                    .tint(Color.danger)
                    .disabled(!MemorySettingsViewModel.resetEnabled(typed))
                    .probeID("memory.reset.confirm")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("memory.reset.sheet")
    }
}
