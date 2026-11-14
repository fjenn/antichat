// AddMenu (components.md; M1.T17 step 1; R-013 AC1; ChatGPT F-027 "+", tooltip `tip.add`): the + button's popover.
// Rows: Add photos & files · Create image · Create video · Web search · Connections · Use project
// (`SlashCommandRegistry.addItems`). A pack that is not installed shows its row disabled with `add.disabled.pack`
// ("Install {pack} to use this"); installed but off, `add.disabled.enable` ("Enable in Settings"), and a click opens
// Settings → Capabilities. Neither state hides the row. Web search and Connections are listed only when they are on
// (M7) and the active model takes tools (D-023). Opens on click (IS-6: submenus on click, not hover); ↑/↓ wrap,
// Return picks, Esc closes (the popover's own Esc). The tray tile of a picked file is AttachmentTileView (M6.T01).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct AddMenu: View {
    @Bindable var menus: ComposerMenus
    @State private var hovered: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            ForEach(Array(menus.addItems.enumerated()), id: \.element.id) { index, item in
                row(item, index: index)
            }
        }
        .padding(PickerCardMetrics.padding)
        .frame(width: PickerCardMetrics.width - 40)
        .background(Color.surfaceRaised)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { menus.moveAdd(1); return .handled }
        .onKeyPress(.upArrow) { menus.moveAdd(-1); return .handled }
        .onKeyPress(.return) { menus.pickAddSelection(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)  // else "addMenu" replaces every addRow.<id> (Q-015 catch-up)
        .probeID("addMenu")
    }

    private func row(_ item: ComposerMenuItem, index: Int) -> some View {
        let title = ComposerMenus.title(item)
        let reason = ComposerMenus.reason(item.state)
        return Button { menus.pickAdd(item) } label: {
            PickerCardItemRow(symbol: item.symbol, title: title, detail: reason?.string,
                              enabled: item.state.isEnabled || item.state == .needsConsent, highlighted: index == menus.addSelection || index == hovered)
        }
        .buttonStyle(.plain)
        // A row that does nothing (not on this Mac, …) is disabled for accessibility too (M5.T08: "dimmed").
        .disabled(!(item.state.isPickable || item.state.isSettingsLink))
        .onHover { h in if h { hovered = index } else if hovered == index { hovered = nil } }
        .help(reason?.string ?? title)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: reason?.string ?? ""))
        .probeID("addRow.\(item.id)")
    }
}
