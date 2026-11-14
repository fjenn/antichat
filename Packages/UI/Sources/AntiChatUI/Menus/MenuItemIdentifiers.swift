// Menu items' accessibility identifiers (Q-015 XCUITest catch-up). SwiftUI does not carry a Commands button's
// `.accessibilityIdentifier("menu.file.newEvilChat")` to its NSMenuItem: every item reported `menuAction:` (the action
// selector), so id-based lookups (UI tests, VoiceOver tooling) never matched. The convention is id = the item's
// copy key; this gives every main-menu item whose title is a `menu.*` copy string that identifier, and re-applies it
// whenever SwiftUI rebuilds a menu.
import AntiChatDesign
import AppKit

@MainActor
public enum MenuItemIdentifiers {
    private static var installed = false
    private static var pending = false

    /// Title → copy key for every `menu.*` string without arguments.
    public static var titles: [String: String] {
        var out: [String: String] = [:]
        for key in CopyKeys.keys(withPrefix: "menu.") {
            let title = CopyKey(key).string()
            if !title.contains("{"), out[title] == nil { out[title] = key }
        }
        return out
    }

    public static func install() {
        guard !installed else { return }
        installed = true
        apply()
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { schedule() }
            }
        }
    }

    private static func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { pending = false; apply() }
    }

    /// Sets the identifier of every item in `menu` (default: the main menu) whose title is a `menu.*` copy string.
    public static func apply(to menu: NSMenu? = NSApp.mainMenu, titles: [String: String] = MenuItemIdentifiers.titles) {
        guard let menu else { return }
        for item in menu.items {
            if let key = titles[item.title], item.identifier?.rawValue != key {
                item.identifier = NSUserInterfaceItemIdentifier(key)
            }
            if let sub = item.submenu { apply(to: sub, titles: titles) }
        }
    }
}
