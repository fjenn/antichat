// Help menu (M1.T24 step 5; M10.T07 R-303 AC1): AntiChat Help (help centre online, bundled guide offline), Keyboard
// Shortcuts ⌘/, Report a Problem…, Privacy, Legal (bundled, versioned), How to Uninstall, What's New.
import AntiChatDesign
import KeyboardShortcuts
import SwiftUI

struct HelpCommands: Commands {
    @FocusedValue(\.windowState) private var focused
    @Environment(\.openSettings) private var openSettings
    private var state: WindowState? { MenuTarget.state(focused) }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button { HelpCentre.open { state?.presentedSheet = .help } } label: { Text(CopyKey("menu.help.centre")) }
                .accessibilityIdentifier("menu.help.centre")
            Button { state?.presentedSheet = .shortcuts } label: { Text(CopyKey("menu.help.shortcuts")) }
                .accessibilityIdentifier("menu.help.shortcuts")
                .menuShortcut(.shortcutList)
            Button { state?.presentedSheet = .report } label: { Text(CopyKey("menu.help.report")) }
                .accessibilityIdentifier("menu.help.report")
            Button {
                SettingsNavigator.shared.request(.privacy)
                openSettings()
            } label: { Text(CopyKey("menu.help.privacy")) }
                .accessibilityIdentifier("menu.help.privacy")
            Button { state?.presentedSheet = .exportLogs } label: { Text(CopyKey("menu.help.exportLogs")) }
                .accessibilityIdentifier("menu.help.exportLogs")  // M8.T09
            Button { state?.presentedSheet = .legal } label: { Text(CopyKey("menu.help.legal")) }
                .accessibilityIdentifier("menu.help.legal")
            Button { state?.presentedSheet = .uninstallHelp } label: { Text(CopyKey("menu.help.uninstall")) }
                .accessibilityIdentifier("menu.help.uninstall")  // M8.T11
            Divider()
            Button { state?.presentedSheet = .whatsNew } label: { Text(CopyKey("menu.help.whatsNew")) }
                .accessibilityIdentifier("menu.help.whatsNew")
                .disabled(WhatsNewNotes.load(version: WhatsNewProvider.currentVersion) == nil)
        }
    }
}
