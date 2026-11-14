// M8.T03 step 3 + 7 (R-060 AC2/AC3, R-246; S-21 §6, settings-map §6): Settings → Personalization → Memory.
// Rows: Memory On / Paused / Off · Include sensitive topics (Off) · Suggest things to remember · Manage memories
// (MemoryBrowserView: topics with counts, search, edit, delete with a 5 s undo, add) · Reset memory (typed RESET)
// · Suggestions (propose-only cards from the background review: [Save] / [Dismiss]).
import AntiChatDesign
import AntiChatKnowledge
import AntiChatStorage
import Defaults
import SwiftUI

struct MemorySettingsSection: View {
    @Bindable var model: MemorySettingsViewModel
    @Default(.memoryIncludeSensitive) private var includeSensitive
    @Default(.memoryReviewEnabled) private var reviewEnabled
    @State private var browsing = false
    @State private var resetting = false

    var body: some View {
        Section {
            SettingsItem("memoryMode") {
                Picker(selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                    Text(CopyKey("set.memory.on")).tag(MemoryPolicy.Mode.on)
                    Text(CopyKey("set.memory.paused")).tag(MemoryPolicy.Mode.paused)
                    Text(CopyKey("set.memory.off")).tag(MemoryPolicy.Mode.off)
                } label: { Text(CopyKey("set.memory.mode")) }
                    .pickerStyle(.menu).fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.memoryMode")
            }
            SettingsItem("memoryIncludeSensitive", description: CopyKey("set.memory.sensitive.note")) {
                Toggle(isOn: $includeSensitive) { Text(CopyKey("set.memory.sensitive")) }
                    .toggleStyle(.accessibleSwitch).labelsHidden()
                    .probeID("settings.control.memoryIncludeSensitive")
            }
            // VQ: the condition is the row's note, not part of its label.
            SettingsItem("memoryReviewEnabled", description: CopyKey("set.memory.suggest.note")) {
                Toggle(isOn: $reviewEnabled) { Text(CopyKey("set.memory.suggest")) }
                    .toggleStyle(.accessibleSwitch).labelsHidden()
                    .probeID("settings.control.memoryReviewEnabled")
            }
            SettingsItem("manageMemories") {
                Button { browsing = true } label: { Text(CopyKey("set.memory.manage.button")) }
                    .probeID("settings.control.manageMemories")
            }
            // VQ: with nothing saved the row says so instead of showing a faint disabled button.
            SettingsItem("resetMemory", description: model.count == 0 ? CopyKey("set.memory.reset.empty") : nil) {
                if model.count > 0 {
                    Button(role: .destructive) { resetting = true } label: {
                        Text(CopyKey("set.memory.reset.button")).foregroundStyle(Color.danger)
                    }
                    .probeID("settings.control.resetMemory")
                }
            }
        }
        .sheet(isPresented: $browsing) { MemoryBrowserView(model: model) { browsing = false } }
        .sheet(isPresented: $resetting) {
            MemoryResetSheet(count: model.count, onReset: { typed in try? model.reset(typed: typed); resetting = false },
                             onCancel: { resetting = false })
        }
        if !model.suggestions.isEmpty {
            Section {
                ForEach(model.suggestions) { s in
                    MemorySuggestionCard(id: s.id, text: s.text, onDismiss: { try? model.dismissSuggestion(s.id) },
                                         onSave: { try? model.saveSuggestion(s.id) })
                }
            } header: { Text(CopyKey("set.memory.suggestions")) }
            .probeID("memory.suggestions")
        }
    }
}

struct MemoryBrowserView: View {
    @Bindable var model: MemorySettingsViewModel
    let onDone: () -> Void
    @State private var editing: String?
    @State private var draft = ""
    @State private var adding = false
    @State private var newTopic = ""
    @State private var newText = ""

    static func originKey(_ o: MemoryOrigin) -> CopyKey {
        switch o {
        case .user: CopyKey("memory.origin.user")
        case .tool: CopyKey("memory.origin.tool")
        case .review: CopyKey("memory.origin.review")
        case .import: CopyKey("memory.origin.import")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text(CopyKey("memory.browser.title")).typeStyle(.title3)
                Spacer()
                Button { adding.toggle() } label: { Label { Text(CopyKey("memory.add")) } icon: { Image(systemName: "plus") } }
                    .probeID("memory.add")
            }
            TextField(text: $model.query) { Text(CopyKey("memory.browser.search")) }
                .textFieldStyle(.roundedBorder)
                .probeID("memory.search")
            if adding {
                HStack {
                    TextField(text: $newTopic) { Text(CopyKey("memory.add.topic")) }.frame(width: 120)
                    TextField(text: $newText) { Text(CopyKey("memory.add.text")) }
                    Button {
                        try? model.add(topic: newTopic.isEmpty ? "General" : newTopic, text: newText)
                        newTopic = ""; newText = ""; adding = false
                    } label: { Text(CopyKey("memory.editor.save")) }
                        .accessibilityIdentifier("memory.editor.save")
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            }
            if model.groups.isEmpty {
                Text(CopyKey("memory.browser.empty")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            } else {
                List {
                    ForEach(model.groups) { g in
                        Section {
                            ForEach(g.entries, id: \.item.id) { e in row(e) }
                        } header: {
                            Text(CopyText(CopyKey("memory.browser.topic"), ["topic": g.name, "count": "\(g.entries.count)"]))
                                .probeID("memory.topic.\(g.name)")
                        }
                    }
                }
                .frame(minHeight: 280)
            }
            if model.lastDeletedEvent != nil {
                Button { try? model.undoDelete() } label: { Text(CopyKey("toast.memoryDeleted")) }
                    .buttonStyle(.link)
                    .task { try? await Task.sleep(for: .seconds(5)) }
                    .probeID("memory.undoDelete")
            }
            HStack { Spacer(); Button(action: onDone) { Text(CopyKey("memory.browser.done")) }.keyboardShortcut(.defaultAction) }
        }
        .padding(Spacing.space5)
        .frame(width: 560)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("memory.browser")
    }

    @ViewBuilder func row(_ e: MemoryEntry) -> some View {
        if editing == e.item.id {
            HStack {
                TextField("", text: $draft).textFieldStyle(.roundedBorder)
                Button { editing = nil } label: { Text(CopyKey("memory.editor.cancel")) }
                    .accessibilityIdentifier("memory.editor.cancel")
                Button { try? model.edit(e.item.id, text: draft); editing = nil } label: { Text(CopyKey("memory.editor.save")) }
                    .accessibilityIdentifier("memory.editor.save")
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft.count > MemoryStore.maxText)
            }
        } else {
            HStack(spacing: Spacing.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.item.text).typeStyle(.body)
                    HStack(spacing: Spacing.space2) {
                        Text(e.item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        Text(Self.originKey(e.item.origin))
                    }
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button { draft = e.item.text; editing = e.item.id } label: { Text(CopyKey("memory.edit")) }
                    .accessibilityIdentifier("memory.edit")
                Button(role: .destructive) { try? model.delete(e.item.id) } label: { Text(CopyKey("memory.delete")) }
                    .probeID("memory.delete.\(e.item.id)")
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
