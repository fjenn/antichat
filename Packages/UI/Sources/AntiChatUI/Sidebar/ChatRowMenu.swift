// The chat ⋯ menu (M1.T07 step 6; ChatGPT F-025): the same items on the sidebar row (hover ⋯ and right-click)
// and in the title bar. Rename ⌥⌘R, Pin/Unpin ⌥⌘P, Move to project › (M8.T04), Export › the Share items (M8.T07) +
// JSON (TreeExport), Archive ⇧⌘A, Delete (red, confirmation popover).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatMenuItems: View {
    let chat: ChatSummary
    let state: WindowState
    var deleteAnchor: WindowState.PendingDelete.Anchor = .row
    /// The toolbar's ⋯ menu leaves Export out: the Share button beside it is the one entry point there.
    var showsExport = true

    var body: some View {
        Button { state.renamingChatID = chat.id } label: { Text(CopyKey("row.rename")) }
            .accessibilityIdentifier("menu.rename")
        Button { state.togglePin(chat.id) } label: { Text(chat.pinned ? CopyKey("row.unpin") : CopyKey("row.pin")) }
            .accessibilityIdentifier("menu.pin")
        MoveToProjectMenu(chatID: chat.id, currentProjectID: chat.projectID, state: state)  // M8.T04
        if showsExport {
        Menu {
            if FeatureFlag.exportAll.isEnabled() {  // M8.T07 step 5: the Share menu's items, then the tree JSON (R-296)
                ShareMenuItems(chatID: chat.id, database: state.service.database)
                Divider()
            } else {
                Button { ChatExporter.save(chat, as: .markdown, state: state) } label: { Text(CopyKey("row.export.markdown")) }
                    .accessibilityIdentifier("menu.export.markdown")
            }
            Button { ChatExporter.save(chat, as: .json, state: state) } label: { Text(CopyKey("row.export.json")) }
                .accessibilityIdentifier("menu.export.json")
        } label: { Text(CopyKey("row.export")) }
        }
        Button {  // M6.T13 (R-017 AC2)
            if state.currentChatID != chat.id { state.open(.chat(chat.id)) }
            state.presentedSheet = .filesInChat
        } label: { Text(CopyKey("chat.filesInChat")) }
            .accessibilityIdentifier("menu.filesInChat")
        Divider()
        Button { state.archive([chat.id]) } label: { Text(CopyKey("row.archive")) }
            .accessibilityIdentifier("menu.archive")
        Button(role: .destructive) { state.requestDelete([chat.id], anchor: deleteAnchor) } label: {
            Text(CopyKey("row.delete"))
        }
        .accessibilityIdentifier("menu.delete")
    }
}

/// The hover ⋯ button on a row.
struct ChatRowMenuButton: View {
    let chat: ChatSummary
    let state: WindowState

    var body: some View {
        Menu {
            ChatMenuItems(chat: chat, state: state)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(CopyKey("chat.more")))
        .accessibilityLabel(Text(CopyKey("chat.more")))
        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
        .probeID("chatRow.more")
    }
}

/// Save panel for Export › Markdown / JSON.
@MainActor
enum ChatExporter {
    static func save(_ chat: ChatSummary, as format: ChatExportFormat, state: WindowState) {
        guard let out = state.export(chat.id, as: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = out.name
        panel.allowedContentTypes = [format == .json ? .json : UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? out.data.write(to: url, options: .atomic)
    }
}
