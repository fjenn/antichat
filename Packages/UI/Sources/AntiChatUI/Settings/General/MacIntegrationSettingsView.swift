// M8.T13 steps 1 and 3 (R-105, R-106; settings-map §1): Settings › General › "Quick panel hotkey" — the
// KeyboardShortcuts recorder (default ⌥Space; its × turns the hotkey off) and, when the combination is taken by
// macOS or another app, `qp.conflict`. The Menu bar item toggle stays in GeneralSection (its key predates M8).
import AntiChatDesign
import KeyboardShortcuts
import SwiftUI

struct QuickPanelHotkeyRow: View {
    @State private var shortcuts = GlobalShortcuts.shared

    var body: some View {
        SettingsItem("quickPanelHotkey",
                     description: shortcuts.conflict ? CopyKey("qp.conflict") : CopyKey("set.general.quickPanel.note")) {
            ShortcutStore.recorder(for: .quickPanel) { _ in GlobalShortcuts.shared.recheck() }
                .accessibilityLabel(Text(CopyKey("set.general.quickPanel")))  // no label of its own (M9.T03)
                .probeID("settings.control.quickPanelHotkey")
                .accessibilityIdentifier("settings.control.quickPanelHotkey")
        }
    }
}
