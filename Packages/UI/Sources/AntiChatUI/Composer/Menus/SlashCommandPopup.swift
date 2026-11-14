// SlashAtMenu (components.md; M1.T17 step 2; R-013 AC2; IS-6, ChatGPT F-027): the inline menu that `/` at the input
// start and `@` at a word start open above the composer, anchored at the trigger.
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Views/Chat/SlashCommandPopup.swift (MIT): heading with
// key hints, a scroll-to-selection list of at most N rows, hover + keyboard highlight, click to pick. Changes: AntiChat rows
// (icon, bold name, grey description or disabled reason; ChatGPT F-027), a "Tools" section for registry tools, the
// empty state ("No matches", components.md), no "New Command" link (custom commands are not an M1 feature), and
// selection/picks go through ComposerMenus (the text view keeps keyboard focus).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct SlashAtMenu: View {
    @Bindable var menus: ComposerMenus
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            PickerCardHeading(title: CopyText(CopyKey("tip.add"))) { PickerCardKeyHints() }
            if menus.isPathMode {
                AtFileMenuPopupList(menus: menus)
            } else if menus.inlineItems.isEmpty {
                Text(CopyKey("slashMenu.empty"))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .pickerCardRowChrome(highlighted: false)
                    .probeID("menuEmpty")
            } else {
                list
            }
        }
        .padding(PickerCardMetrics.padding)
        .frame(width: PickerCardMetrics.width)
        .pickerCardSurface(elevated: true)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("slashAtMenu")
    }

    private var list: some View {
        let items = menus.inlineItems
        let firstTool = items.firstIndex { $0.group == .tools }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: items.count > PickerCardMetrics.maxVisibleRows) {
                VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == firstTool, index > 0 {
                            PickerCardSectionTitle(title: CopyText(CopyKey("slashMenu.tools")))
                        }
                        row(item, index: index).id(index)
                    }
                }
            }
            .frame(height: Self.listHeight(items))
            .onChange(of: menus.selection) { _, i in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    /// Height of the visible rows (the list scrolls beyond `maxVisibleRows`).
    static func listHeight(_ items: [ComposerMenuItem]) -> CGFloat {
        let visible = items.prefix(PickerCardMetrics.maxVisibleRows)
        let rows = visible.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        let tools = visible.contains { $0.group == .tools } && visible.first?.group != .tools ? 22 : 0
        return rows + CGFloat(max(0, visible.count - 1)) * PickerCardMetrics.rowSpacing + CGFloat(tools)
    }

    static func rowHeight(_ item: ComposerMenuItem) -> CGFloat {
        detail(item) == nil ? PickerCardMetrics.rowHeight : PickerCardMetrics.detailRowHeight
    }

    static func detail(_ item: ComposerMenuItem) -> String? {
        ComposerMenus.reason(item.state)?.string ?? item.detail
    }

    private func row(_ item: ComposerMenuItem, index: Int) -> some View {
        let title = ComposerMenus.title(item)
        return Button { menus.pickInline(item) } label: {
            PickerCardItemRow(symbol: item.symbol, title: title, detail: Self.detail(item),
                              enabled: item.state.isEnabled || item.state == .needsConsent, highlighted: index == menus.selection || index == hovered)
        }
        .buttonStyle(.plain)
        .onHover { h in if h { hovered = index } else if hovered == index { hovered = nil } }
        .help(Self.detail(item) ?? title)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: Self.detail(item) ?? ""))
        .accessibilityAddTraits(index == menus.selection ? [.isSelected] : [])
        .probeID("menuRow.\(item.id)")
    }
}
