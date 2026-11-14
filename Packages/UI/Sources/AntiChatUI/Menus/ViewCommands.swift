// View menu (M1.T24 step 5): Toggle Sidebar ⇧⌘S, Toggle Side Panel (M4), Back ⌘[ / Forward ⌘], Search ⌘K,
// Find in Chat ⌘F.
import AntiChatDesign
import KeyboardShortcuts
import SwiftUI

struct ViewCommands: Commands {
    @FocusedValue(\.windowState) private var focused
    private var state: WindowState? { MenuTarget.state(focused) }
    @FocusedValue(\.paletteController) private var focusedPalette
    private var palette: PaletteController? { MenuTarget.palette(focusedPalette, state: focused) }

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button { state?.toggleSidebar() } label: { Text(CopyKey("menu.view.sidebar")) }
                .accessibilityIdentifier("menu.view.sidebar")
                .menuShortcut(.toggleSidebar)
            Button {} label: { Text(CopyKey("menu.view.panel")) }
                .accessibilityIdentifier("menu.view.panel")
                .disabled(true)  // M4
            Divider()
            Button { state?.goBack() } label: { Text(CopyKey("nav.back")) }
                .accessibilityIdentifier("nav.back")
                .menuShortcut(.back)
            Button { state?.goForward() } label: { Text(CopyKey("nav.forward")) }
                .accessibilityIdentifier("nav.forward")
                .menuShortcut(.forward)
            Divider()
            // M1.T11: ⌘K opens (or closes) the window's palette (R-012).
            Button { palette?.toggle() } label: { Text(CopyKey("side.search")) }
                .accessibilityIdentifier("side.search")
                .menuShortcut(.palette)
            // M1.T24: ⌘F opens (or refocuses) the find bar of the window's visible chat.
            Button { state?.conversation?()?.find.present() } label: { Text(CopyKey("shortcut.find")) }
                .accessibilityIdentifier("shortcut.find")
                .menuShortcut(.findInChat)  // no-op outside a chat (a computed `.disabled` went stale in menus)
        }
    }
}
