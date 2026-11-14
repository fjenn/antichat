// The window a menu command acts on (M1.T24): the focused scene's values, else the key (or main) window's state.
// SwiftUI publishes focused scene values only while the app is active; a key equivalent can arrive without them
// (e.g. right after activation), so the commands resolve their target when they run.
import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
enum MenuTarget {
    static func state(_ focused: WindowState?) -> WindowState? {
        if let focused { return focused }
        let states = IncognitoQuitGuard.states
        let app = NSApp as NSApplication?  // nil: a headless process (no application object)
        return states.first { $0.window != nil && $0.window === app?.keyWindow }
            ?? states.first { $0.window != nil && $0.window === app?.mainWindow }
    }

    /// `state(_:)`, else the front-most visible main window (a menu used before any window is key).
    static func frontmost(_ focused: WindowState?) -> WindowState? {
        if let s = state(focused) { return s }
        let states = IncognitoQuitGuard.states.filter { $0.window?.isVisible == true }
        let order = NSApp.orderedWindows
        return states.min { a, b in
            (order.firstIndex { $0 === a.window } ?? .max) < (order.firstIndex { $0 === b.window } ?? .max)
        }
    }

    static func palette(_ focused: PaletteController?, state: WindowState?) -> PaletteController? {
        focused ?? MenuTarget.state(state)?.palette
    }
}

extension View {
    /// The current combo of `name` as this menu item's key equivalent (observable: a rebinding updates the menu).
    @MainActor
    func menuShortcut(_ name: KeyboardShortcuts.Name) -> some View {
        keyboardShortcut(ShortcutBindings.shared[name])
    }
}
