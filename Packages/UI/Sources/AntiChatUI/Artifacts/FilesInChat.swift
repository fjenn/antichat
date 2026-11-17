// M6.T13 steps 5 and 7 (R-016 AC5, R-017 AC2; S-15, S-24): the toolbar's Outputs list (`panel.outputs`: every file
// the chat produced, newest first, click → side panel) and the chat ⋯ menu's "Files in this chat" sheet
// (`chat.filesInChat`: attached + produced files with name, kind, size, date; click → side panel; empty →
// `chat.filesInChat.empty`). Rows come from `ChatFilesQuery` through `MainWindowSlots.chatFiles`.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

extension EnvironmentValues {
    /// The window's side panel (M6.T13): cards and tiles open their file in it; nil outside a chat window.
    @Entry public var sidePanel: SidePanelModel? = nil
}

extension SidePanelModel {
    /// Opens a chat file (latest version) in the panel.
    public func open(_ file: ChatFile) {
        open(file: URL(fileURLWithPath: file.path), title: file.name)
        // M6.T13: a promoted Vega-Lite block is stored as .json; its kind says it is a chart.
        if file.kind == "chart", (file.path as NSString).pathExtension.lowercased() == "json" { setPreview(.vega) }
    }
}

/// One row: icon, name, "KIND · size · date", a deleted note when the media-store file is gone.
struct ChatFileRow: View {
    let file: ChatFile

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: file.origin == .produced ? "doc.badge.plus" : "paperclip")
                .foregroundStyle(Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name).typeStyle(.bodyEmph).foregroundStyle(Color.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: Self.subtitle(file)).typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.space2)
            if !file.exists {
                Text(CopyKey("file.deleted")).typeStyle(.caption).foregroundStyle(Color.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// VQ-M10: the Files-in-this-chat table's height for `rows` rows (header + rows, at most ten before it scrolls).
    static func tableHeight(rows: Int) -> CGFloat { 30 + CGFloat(min(max(rows, 1), 10)) * 26 }

    static func kindLabel(_ f: ChatFile) -> String {
        let ext = (f.name as NSString).pathExtension
        return FileCardViewModel.kindLabel(ext: ext.isEmpty ? f.kind : ext)  // "Word document", "PNG"
    }

    static func subtitle(_ f: ChatFile) -> String {
        [kindLabel(f), ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file),
         f.date.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · ")
    }
}

/// `panel.outputs`: the chat's produced files, newest first.
public struct OutputsListView: View {
    let files: [ChatFile]
    let onSelect: (ChatFile) -> Void

    public init(files: [ChatFile], onSelect: @escaping (ChatFile) -> Void) {
        self.files = files.filter { $0.origin == .produced }
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("panel.outputs")).typeStyle(.headline).foregroundStyle(Color.textPrimary)
            if files.isEmpty {
                Text(CopyKey("chat.filesInChat.empty")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        ForEach(files) { f in
                            Button { onSelect(f) } label: { ChatFileRow(file: f) }
                                .buttonStyle(.plain)
                                .disabled(!f.exists)
                                .accessibilityIdentifier("outputsRow")
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(Spacing.space4)
        .frame(width: 340)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("outputsList")
    }
}

/// `chat.filesInChat`: attached and produced files of the chat.
public struct FilesInChatSheet: View {
    let files: [ChatFile]
    let onSelect: (ChatFile) -> Void
    let onClose: () -> Void

    public init(files: [ChatFile], onSelect: @escaping (ChatFile) -> Void, onClose: @escaping () -> Void) {
        self.files = files
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("chat.filesInChat")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            if files.isEmpty {
                Text(CopyKey("chat.filesInChat.empty")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityIdentifier("filesInChatEmpty")
            } else {
                // VQ-M11 S-24: column titles from the copy deck (they were hard-coded English), a file icon before
                // each name, and the date column wide enough for the locale's medium date.
                Table(files) {
                    TableColumn(Text(CopyKey("files.col.name"))) { f in
                        HStack(spacing: Spacing.space2) {
                            Image(systemName: f.origin == .produced ? "doc.badge.plus" : "doc")
                                .foregroundStyle(Color.textSecondary).frame(width: 16).accessibilityHidden(true)
                            Button { onSelect(f) } label: { Text(verbatim: f.name).lineLimit(1).truncationMode(.middle) }
                                .buttonStyle(.link)
                                .disabled(!f.exists)
                                .accessibilityIdentifier("filesInChat.open")
                        }
                    }
                    TableColumn(Text(CopyKey("files.col.kind"))) { f in
                        Text(verbatim: ChatFileRow.kindLabel(f)).foregroundStyle(Color.textSecondary)
                    }.width(150)
                    TableColumn(Text(CopyKey("files.col.size"))) { f in
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)).monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                    }.width(80)
                    TableColumn(Text(CopyKey("files.col.date"))) { f in
                        Text(verbatim: f.exists ? f.date.formatted(date: .abbreviated, time: .shortened) : CopyKey("file.deleted").string())
                            .foregroundStyle(Color.textSecondary)
                    }.width(170)
                }
                // VQ-M10 S-15/S-24: as tall as its rows (a fixed 240 pt showed empty striped rows that read as
                // loading skeletons under two real files), scrolling past ten.
                .frame(height: ChatFileRow.tableHeight(rows: files.count))
                .alternatingRowBackgrounds(.disabled)
                .accessibilityIdentifier("filesInChatTable")
            }
            HStack {  // VQ-M11 S-24: the sheet's one action at the bottom right, as every other sheet
                Spacer()
                Button(action: onClose) { Text(CopyKey("panel.close")) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .accessibilityIdentifier("filesInChat.close")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 640)
        .onExitCommand(perform: onClose)  // Esc still closes
    }
}
