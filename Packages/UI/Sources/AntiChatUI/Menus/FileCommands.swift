// File menu (M1.T24 step 5): New Chat ⌘N, New Incognito Chat ⇧⌘N (a new incognito window; M1.T20's in-window
// toggle stays on the toolbar), New Evil Chat ⇧⌘E (inert until Evil Mode is enabled, M2), New Project (M8),
// New Window ⌥⌘N, then the standard Close ⌘W.
import AntiChatDesign
import AntiChatFoundation
import KeyboardShortcuts
import SwiftUI

/// The `WindowGroup(for: MainWindowValue.self)` value of a main window (M1.T24 step 6): the chat it shows (restored
/// on relaunch) or a request for a fresh incognito window.
public enum MainWindowValue: Codable, Hashable, Sendable {
    case chat(String)
    case incognito

    public var chatID: String? { if case .chat(let id) = self { id } else { nil } }
}

public enum MainWindowID {
    public static let main = "main"
}

struct FileCommands: Commands {
    @FocusedValue(\.windowState) private var focused
    private var state: WindowState? { MenuTarget.state(focused) }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                if let state { state.newChat() } else { openWindow(id: MainWindowID.main) }
            } label: { Text(CopyKey("menu.file.newChat")) }
                .accessibilityIdentifier("menu.file.newChat")
                .menuShortcut(.newChat)
            Button { openWindow(id: MainWindowID.main, value: MainWindowValue.incognito) } label: {
                Text(CopyKey("menu.file.newIncognito"))
            }
                .accessibilityIdentifier("menu.file.newIncognito")
            .menuShortcut(.newIncognito)
            // M2.T17 (R-210 AC1/AC6): New Evil Chat ⇧⌘E — present only while Evil Mode is on and not hidden.
            if EvilModeModel.shared?.showsSwitch == true {
                // Resolved at click time, never disabled on a missing focused value: Commands are not re-evaluated when a
                // window becomes key, so `.disabled(state == nil)` left the item dead right after launch until the
                // composer took focus (Q-015 XCUITest catch-up).
                Button {
                    if let target = MenuTarget.frontmost(focused) { target.newEvilChat() } else { openWindow(id: MainWindowID.main) }
                } label: { Text(CopyKey("menu.file.newEvilChat")) }
                    .accessibilityIdentifier("menu.file.newEvilChat")
                    .menuShortcut(.newEvilChat)
            }
            Button {} label: { Text(CopyKey("menu.file.newProject")) }
                .accessibilityIdentifier("menu.file.newProject")
                .disabled(true)  // M8
            if FeatureFlag.importChats.isEnabled() {  // M8.T06 step 2: Settings › Privacy & Data with the import sheet up
                Button {
                    ImportRequest.shared.request()
                    SettingsNavigator.shared.request(.privacy, row: "importChats")
                    openSettings()
                } label: { Text(CopyKey("menu.file.import")) }
                    .accessibilityIdentifier("menu.file.import")
            }
            if FeatureFlag.exportAll.isEnabled() {  // M8.T07 step 2: Settings › Privacy & Data with the export sheet up
                Button {
                    ExportRequest.shared.request()
                    SettingsNavigator.shared.request(.privacy, row: "exportAll")
                    openSettings()
                } label: { Text(CopyKey("menu.file.exportAll")) }
                    .accessibilityIdentifier("menu.file.exportAll")
            }
            Divider()
            Button { openWindow(id: MainWindowID.main) } label: { Text(CopyKey("menu.file.newWindow")) }
                .accessibilityIdentifier("menu.file.newWindow")
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}
