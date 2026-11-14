// Settings → Privacy & Data → Archived chats (M1.T22 step 5; R-011 AC4; copy `archived.*`): every archived chat,
// newest first, a search field that filters by title, and per row Unarchive and Delete (Delete asks first, as in
// the sidebar). The list observes the database, so the sidebar and this page always agree.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct ArchivedChatsPage: View {
    let chats: ChatListService?
    let onDone: () -> Void

    @State private var rows: [ArchivedChat] = []
    @State private var query = ""
    @State private var pendingDelete: String?
    @State private var token: ObservationToken?

    private var visible: [ArchivedChat] {
        ArchivedChat.filter(rows, query: query, untitled: CopyKey("side.untitled").string())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text(CopyKey("archived.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                Spacer()
                Button(action: onDone) { Text(CopyKey("archived.done")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("archived.done")
            }
            HStack(spacing: Spacing.space1) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                TextField(text: $query) { Text(CopyKey("archived.search")) }
                    .textFieldStyle(.plain)
                    .probeID("archived.search")
            }
            // The row is the field's line height (16 pt), not whichever of the symbol and the field measures taller:
            // the magnifier's measured height varied by 1 pt between renders under parallel test load, which moved
            // the whole centred page by a pixel (settings-archived-page flake, 2026-11-08).
            .frame(height: 16)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, 6)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            if visible.isEmpty {
                Text(CopyKey("archived.empty"))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .probeID("archived.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { chat in
                            row(chat)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 560, height: 460)
        .background(Color.surfaceCanvas)
        .onAppear {
            token = chats?.observeArchived { rows = $0 }
        }
        .onDisappear { token?.cancel() }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("archived.page")
    }

    private func row(_ chat: ArchivedChat) -> some View {
        HStack(spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chat.title.isEmpty ? CopyKey("side.untitled").string() : chat.title)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(chat.archivedAt, format: .dateTime.day().month().year())
                    .typeStyle(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Button { try? chats?.unarchive(chat.id) } label: { Text(CopyKey("archived.unarchive")) }
                .probeID("archived.unarchive.\(chat.id)")
            Button(role: .destructive) { pendingDelete = chat.id } label: { Text(CopyKey("row.delete")) }
                .probeID("archived.delete.\(chat.id)")
                .popover(isPresented: Binding(get: { pendingDelete == chat.id },
                                              set: { if !$0 { pendingDelete = nil } })) {
                    DeleteConfirmation(
                        title: chat.title,
                        message: CopyText(CopyKey("row.delete.confirm"),
                                          ["title": chat.title.isEmpty ? CopyKey("side.untitled").string() : chat.title]),
                        onConfirm: { try? chats?.delete([chat.id]); pendingDelete = nil },
                        onCancel: { pendingDelete = nil })
                }
        }
        .padding(.vertical, Spacing.space2)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("archived.row.\(chat.id)")
    }
}
