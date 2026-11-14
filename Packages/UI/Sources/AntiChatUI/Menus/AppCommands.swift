// Native menus (M1.T24 step 5; R-104): File, Edit (standard + Copy Last Code Block), View, Window (standard), Help.
// Every rebindable item takes its combo from KeyboardShortcuts (`globalKeyboardShortcut`: an in-app key equivalent
// that follows a rebinding at once, never a system hotkey), so the menus are the single dispatcher (no double fire).
// `AppCommands` is the scene's `.commands` content; it replaces M1.T07's MainWindowCommands.
import AntiChatDesign
import AntiChatFoundation
import KeyboardShortcuts
import SwiftUI

public struct AppCommands: Commands {
    public init() {}

    public var body: some Commands {
        FileCommands()
        EditCommands()  // Cut/Copy/Paste/Select All (transcript-only ⌘A)
        CopyLastCodeCommands()  // M1.T09: Edit › Copy Last Code Block
        ViewCommands()
        ChatCommands()
        HelpCommands()
        UninstallCommands()  // M8.T11: AntiChat › Uninstall AntiChat…
    }
}

/// M8.T11 (R-226 AC1): AntiChat › Uninstall AntiChat… after About (`ff.uninstall` off hides it; the Storage row stays).
struct UninstallCommands: Commands {
    @FocusedValue(\.windowState) private var focused
    private var state: WindowState? { MenuTarget.state(focused) }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if FeatureFlag.uninstall.isEnabled() {
                Button { state?.presentedSheet = .uninstall } label: { Text(CopyKey("set.storage.uninstall")) }
                    .accessibilityIdentifier("set.storage.uninstall")
            }
        }
    }
}

/// The current chat's actions (Rename ⌥⌘R, Pin ⌥⌘P, Archive ⇧⌘A, Delete ⇧⌘⌫), after the Edit menu's find group.
struct ChatCommands: Commands {
    /// Runs `body` with the target window and its current chat (resolved when the command runs).
    @MainActor
    private func withChat(_ body: (WindowState, String) -> Void) {
        if let s = state, let chat = s.currentChatID { body(s, chat) }
    }

    @FocusedValue(\.windowState) private var focused
    private var state: WindowState? { MenuTarget.state(focused) }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button { withChat { $0.renamingChatID = $1 } } label: { Text(CopyKey("row.rename")) }
                .accessibilityIdentifier("row.rename")
                .menuShortcut(.renameChat)
            Button { withChat { $0.togglePin($1) } } label: { Text(CopyKey("row.pin")) }
                .accessibilityIdentifier("row.pin")
                .menuShortcut(.pinChat)
            Button { withChat { $0.archive([$1]) } } label: { Text(CopyKey("row.archive")) }
                .accessibilityIdentifier("row.archive")
                .menuShortcut(.archiveChat)
            // Its own title: SwiftUI gave the standard Edit › Delete item (same "Delete" title) this item's ⇧⌘⌫, so
            // the key went to `delete:` and no confirmation showed (the A-M1-T24a (f) "dead" ⇧⌘⌫).
            Button { withChat { $0.requestDelete([$1], anchor: .toolbar) } } label: { Text(CopyKey("menu.edit.deleteChat")) }
                .accessibilityIdentifier("menu.edit.deleteChat")
                .menuShortcut(.deleteChat)
        }
    }
}
