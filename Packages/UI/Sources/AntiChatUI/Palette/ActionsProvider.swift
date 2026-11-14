// ⌘K actions (M1.T11 step 4, R-012 AC2): New chat, New incognito chat, open each Settings page, Switch chat
// (shows the recent chats), Toggle sidebar. "Keyboard shortcuts" is the Settings › Keyboard shortcuts page until
// M1.T24's shortcut list (⌘/) exists.
import AntiChatDesign
import SwiftUI

/// What an action row does.
public enum PaletteAction: Hashable, Sendable {
    case newChat
    case newIncognitoChat
    case openSettings(SettingsSection)
    /// Shows the Chats tab with the recent chats (the palette stays open).
    case switchChat
    case toggleSidebar
}

@MainActor
enum ActionsProvider {
    /// Every action, in the order the Actions tab lists them for an empty query.
    static var all: [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "action.newChat", kind: .action(.newChat), group: .actions,
                        title: CopyKey("side.newChat").string(), symbol: "square.and.pencil", shortcut: "⌘N",
                        keywords: ["new", "start", "conversation"]),
            PaletteItem(id: "action.newIncognitoChat", kind: .action(.newIncognitoChat), group: .actions,
                        title: CopyKey("palette.action.newIncognito").string(), symbol: "eye.slash",
                        keywords: ["private", "temporary"]),
            PaletteItem(id: "action.switchChat", kind: .action(.switchChat), group: .actions,
                        title: CopyKey("palette.action.switchChat").string(),
                        symbol: "bubble.left.and.bubble.right", keywords: ["recent", "open", "go to"]),
            PaletteItem(id: "action.toggleSidebar", kind: .action(.toggleSidebar), group: .actions,
                        title: CopyKey("palette.action.toggleSidebar").string(), symbol: "sidebar.left",
                        keywords: ["hide", "show"]),
        ]
        let settings = CopyKey("side.settings").string()
        items += SettingsSection.allCases.map { section in
            PaletteItem(id: "action.settings.\(section.rawValue)", kind: .action(.openSettings(section)),
                        group: .actions, title: section.title.string(), subtitle: settings, symbol: section.symbol,
                        keywords: ["settings", "preferences"])
        }
        return items
    }

    /// Actions matching `query` (all for an empty query), best first.
    static func actions(matching query: String) -> [PaletteItem] {
        let scored: [(PaletteItem, Int)] = all.compactMap { item in
            PaletteMatch.score(query, fields: [item.title, item.subtitle ?? ""] + item.keywords).map { (item, $0) }
        }
        return PaletteMatch.ranked(scored)
    }
}
