// The "@" path list inside SlashAtMenu (M1.T17 step 2): shown when the text after "@" is a path (`@~/…`, `@/…`).
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Views/Chat/AtFileMenuPopup.swift (MIT): folder/file
// rows (folders first, "name/"), the empty row, the denied-access row and scroll-to-selection. Changes: it is a section
// of SlashAtMenu (one card, one heading) instead of its own popup, AntiChat tokens and copy (`menu.files.*`), and the
// denied row only explains (no open-panel re-grant in M1; file intake and folder access are M6).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct AtFileMenuPopupList: View {
    @Bindable var menus: ComposerMenus
    @State private var hovered: Int?

    var body: some View {
        let items = menus.fileItems
        if menus.fileResult?.status == .denied {
            row(symbol: "lock.fill",
                text: CopyText(CopyKey("slashMenu.files.denied"),
                               ["folder": URL(fileURLWithPath: menus.fileResult?.directory ?? "/").lastPathComponent]))
                .probeID("menuFilesDenied")
        } else if items.isEmpty {
            row(symbol: "folder", text: CopyText(CopyKey("slashMenu.files.empty")))
                .probeID("menuFilesEmpty")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: items.count > PickerCardMetrics.maxVisibleRows) {
                    VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            fileRow(item, index: index).id(index)
                        }
                    }
                }
                .frame(height: CGFloat(min(items.count, PickerCardMetrics.maxVisibleRows)) * PickerCardMetrics.rowHeight
                       + CGFloat(max(0, min(items.count, PickerCardMetrics.maxVisibleRows) - 1)) * PickerCardMetrics.rowSpacing)
                .onChange(of: menus.selection) { _, i in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
    }

    private func row(symbol: String, text: CopyText) -> some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 18)
            Text(text)
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .pickerCardRowChrome(highlighted: false)
    }

    private func fileRow(_ item: AtFileItem, index: Int) -> some View {
        let highlighted = index == menus.selection || index == hovered
        return Button { menus.pickFile(item) } label: {
            HStack(spacing: Spacing.space3) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(highlighted ? Color.textPrimary : Color.textSecondary)
                    .frame(width: 18)
                Text(verbatim: item.isDirectory ? "\(item.name)/" : item.name)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .pickerCardRowChrome(highlighted: highlighted)
        }
        .buttonStyle(.plain)
        .onHover { h in if h { hovered = index } else if hovered == index { hovered = nil } }
        .probeID("menuFile.\(item.name)")
    }
}
