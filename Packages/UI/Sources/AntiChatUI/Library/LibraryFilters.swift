// M5.T13 step 1 (R-022 AC1; S-19): the Library header controls — All / Images / Videos / Files, the search field over
// names and prompts (`library.search`, library_fts) and the Grid / List switch.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

extension LibraryFilter {
    var title: CopyKey {
        switch self {
        case .all: CopyKey("library.filter.all")
        case .images: CopyKey("library.filter.images")
        case .videos: CopyKey("library.filter.videos")
        case .files: CopyKey("library.filter.files")
        }
    }
}

struct LibraryFilters: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Picker(selection: $model.filter) {
                ForEach(LibraryFilter.allCases, id: \.self) { f in Text(f.title).tag(f) }
            } label: { EmptyView() }
                .pickerStyle(.segmented).accentFilledSegments()
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("library.filter")
            Spacer(minLength: Spacing.space2)
            HStack(spacing: Spacing.space1) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.textTertiary)
                TextField(text: $model.query) { Text(CopyKey("library.search")) }
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("library.search")
            }
            .padding(.horizontal, Spacing.space2)
            .frame(width: 240, height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
            Picker(selection: $model.layout) {
                Image(systemName: "square.grid.2x2").help(CopyKey("library.grid").string())
                    .accessibilityLabel(Text(CopyKey("library.grid"))).tag(LibraryModel.Layout.grid)
                Image(systemName: "list.bullet").help(CopyKey("library.list").string())
                    .accessibilityLabel(Text(CopyKey("library.list"))).tag(LibraryModel.Layout.list)
            } label: { EmptyView() }
                .pickerStyle(.segmented).accentFilledSegments()
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("library.layout")
        }
    }
}
