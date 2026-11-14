// Chats page (M1.T07 step 7; `chats.page.title`): every non-archived chat in a table with multi-select
// (⌘-click, ⇧-click, ⌘A) and bulk Archive / Delete (delete asks first).
// VQ-M10 polish (blind QA "plain dense table, no search/empty state, near-invisible disabled buttons", the ChatGPT
// chat-history list as reference): a search field filters by title, Archive / Delete appear only once rows are
// selected, a double-click (or Return) opens the chat, the table sits on the canvas in both appearances, and an empty
// list says so.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct ChatsPage: View {
    @Bindable var state: WindowState
    @State private var all: [ChatSummary] = []
    @State private var selection = Set<ChatSummary.ID>()
    @State private var token: ObservationToken?
    @State private var query = ""

    private var shown: [ChatSummary] { Self.filter(all, query: query, untitled: CopyKey("side.untitled").string()) }

    /// Chats whose title contains every word of `query` (case- and diacritic-insensitive); all for an empty query.
    static func filter(_ chats: [ChatSummary], query: String, untitled: String) -> [ChatSummary] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return chats }
        return chats.filter { chat in
            let title = chat.title.isEmpty ? untitled : chat.title
            return words.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(spacing: Spacing.space3) {
                Text(CopyKey("chats.page.title"))
                    .typeStyle(.title3)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if !selection.isEmpty {
                    Button { state.archive(Array(selection)); selection.removeAll() } label: {
                        Text(CopyKey("row.archive"))
                    }
                    .probeID("chats.archive")
                    Button(role: .destructive) { state.requestDelete(Array(selection), anchor: .chatsPage) } label: {
                        Text(CopyKey("row.delete"))
                    }
                    .probeID("chats.delete")
                    .popover(isPresented: Binding(get: { state.pendingDelete?.anchor == .chatsPage },
                                                  set: { if !$0 { state.pendingDelete = nil } })) {
                        DeleteConfirmation(title: "", message: CopyText(CopyKey("chats.delete.confirm")),
                                           onConfirm: { state.confirmDelete(); selection.removeAll() },
                                           onCancel: { state.pendingDelete = nil })
                    }
                }
            }
            .frame(minHeight: 28)
            HStack(spacing: Spacing.space2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.textTertiary)
                TextField(CopyKey("chats.search").string(), text: $query)
                    .textFieldStyle(.plain)
                    .typeStyle(.callout)
                    .probeID("chats.search")
            }
            .padding(.horizontal, Spacing.space3)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken))
            if all.isEmpty || shown.isEmpty {
                Text(all.isEmpty ? CopyKey("chats.empty") : CopyKey("library.empty.search"))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .probeID("chats.empty")
            } else {
                Table(shown, selection: $selection) {
                    TableColumn(Text(CopyKey("chats.col.title"))) { chat in
                        Text(verbatim: chat.title.isEmpty ? CopyKey("side.untitled").string() : chat.title)
                            .typeStyle(.callout)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .padding(.vertical, Spacing.space1)
                    }
                    TableColumn(Text(CopyKey("chats.col.updated"))) { chat in
                        Text(chat.updatedAt, format: .dateTime.day().month().year().hour().minute())
                            .typeStyle(.subhead)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(min: 120, ideal: 180, max: 240)
                }
                .contextMenu(forSelectionType: ChatSummary.ID.self) { _ in } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { state.open(.chat(id)) }
                }
                // M9.T08: no zebra stripes — with a few chats the empty striped rows filled the page like placeholders.
                .alternatingRowBackgrounds(.disabled)
                // VQ-M10: the same canvas in light and dark (dark drew the table on its own raised panel).
                .scrollContentBackground(.hidden)
                .probeID("chats.table")
            }
        }
        .padding(Spacing.space6)
        .background(Color.surfaceCanvas)
        .onChange(of: query) { _, _ in selection.formIntersection(shown.map(\.id)) }
        .onAppear {
            token = state.service.observeSidebar(limit: Int.max) { rows in
                all = rows
                selection.formIntersection(rows.map(\.id))
            }
        }
        .onDisappear { token?.cancel() }
    }
}
