// M5.T13 (R-022 AC1–AC4, R-045 AC2; S-19; P-files-tools-08): the Library page behind the sidebar's "Library" item.
// Header: `library.title`, LibraryFilters (All / Images / Videos / Files, search over names and prompts, Grid / List).
// Grid (default): LazyVGrid of LibraryItemCell; List: a Table (name, type, date, size). Newest first. Empty:
// `library.empty` (or `library.empty.search` while searching). Every item: click → VideoViewer (clips) or Quick Look
// (pictures, files); context menu Open chat / Save As… / Show in Finder / Delete (confirmation `library.delete.confirm`);
// drag-out hands over a copy named like the item. Evil items carry `badge.evil` and appear only while "Show Evil items
// in Library" is on. Incognito never appears here (LibraryIndex lists nothing from an in-memory database).
import AntiChatDesign
import AntiChatStorage
import QuickLook
import SwiftUI

public struct LibraryView: View {
    @Bindable var model: LibraryModel

    public init(model: LibraryModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack {
                Text(CopyKey("library.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            LibraryFilters(model: model)
            content
        }
        .padding(Spacing.space6)
        .background(Color.surfaceCanvas)
        .quickLookPreview($model.quickLookURL)
        .overlay { if let t = model.videoViewer { VideoViewer(target: t) { model.videoViewer = nil }.id(t.id) } }
        .confirmationDialog(Text(confirmText), isPresented: Binding(get: { model.pendingDelete != nil },
                                                                     set: { if !$0 { model.pendingDelete = nil } })) {
            Button(role: .destructive) { model.confirmDelete() } label: { Text(CopyKey("library.delete")) }
                .accessibilityIdentifier("library.delete.confirm")
        }
        .onAppear { model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library")
    }

    private var confirmText: String {
        CopyText(CopyKey("library.delete.confirm"), ["name": model.pendingDelete?.name ?? ""]).string
    }

    @ViewBuilder private var content: some View {
        if model.items.isEmpty {
            VStack(spacing: Spacing.space3) {
                Image(systemName: "books.vertical").font(.system(size: 32)).foregroundStyle(Color.textTertiary)
                Text(CopyKey(model.isSearching ? "library.empty.search" : "library.empty"))
                    .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.empty")
        } else if model.layout == .grid {
            grid
        } else {
            list
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: LibraryItemCell.side, maximum: LibraryItemCell.side + 24),
                                             spacing: Spacing.space4, alignment: .top)],
                          alignment: .leading, spacing: Spacing.space4) {
                    ForEach(model.items) { item in
                        LibraryItemCell(item: item, selected: model.selection.contains(item.id))
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(item) }
                            .onTapGesture { model.selection = [item.id] }
                            .onDrag { model.itemProvider(item) }
                            .contextMenu { menu(item) }
                            .onKeyPress(.space) { model.open(item); return .handled }
                            .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space opens the item
                            .accessibilityAction { model.open(item) }
                    }
                }
                .padding(.vertical, Spacing.space1)
            }
            .onChange(of: model.highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .accessibilityIdentifier("library.grid")
        }
    }

    private var list: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn(Text(CopyKey("library.col.name"))) { item in
                HStack(spacing: Spacing.space2) {
                    LibraryThumbnail(item: item, side: 28)
                    Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                    if item.kind == .video { LibraryClipBadge(facts: ClipFacts(item)) }
                    if item.isEvil { LibraryEvilBadge() }
                }
                .onDrag { model.itemProvider(item) }
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .accessibilityIdentifier("library.row")
            }
            TableColumn(Text(CopyKey("library.col.type"))) { item in
                Text(verbatim: Self.typeLabel(item)).foregroundStyle(Color.textSecondary)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn(Text(CopyKey("library.col.date"))) { item in
                Text(item.createdAt, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(Color.textSecondary)
            }
            .width(min: 120, ideal: 170, max: 220)
            TableColumn(Text(CopyKey("library.col.size"))) { item in
                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(Color.textSecondary)
            }
            .width(min: 60, ideal: 80, max: 120)
        }
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            if let id = ids.first, let item = model.items.first(where: { $0.id == id }) { menu(item) }
        } primaryAction: { ids in
            if let id = ids.first, let item = model.items.first(where: { $0.id == id }) { model.open(item) }
        }
        .accessibilityIdentifier("library.list")
    }

    static func typeLabel(_ item: LibraryEntry) -> String {
        let ext = (item.name as NSString).pathExtension
        return (ext.isEmpty ? (item.path as NSString).pathExtension : ext).uppercased()
    }

    @ViewBuilder private func menu(_ item: LibraryEntry) -> some View {
        Button { model.openChat(item) } label: { Text(CopyKey("library.openChat")) }
            .accessibilityIdentifier("library.openChat")
        Button { Task { await model.saveAs(item) } } label: { Text(CopyKey("file.saveAs")) }
            .accessibilityIdentifier("library.saveAs")
        Button { model.reveal(item) } label: { Text(CopyKey("library.reveal")) }
            .accessibilityIdentifier("library.reveal")
        Divider()
        Button(role: .destructive) { model.requestDelete(item) } label: { Text(CopyKey("library.delete")) }
            .accessibilityIdentifier("library.delete")
    }
}
