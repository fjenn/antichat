// Keyboard shortcuts (M1.T24 step 1; R-103 default list, settings-map §12; P-shell-16 `sindresorhus/KeyboardShortcuts`
// 3.1.0). Each rebindable action is a `KeyboardShortcuts.Name` with its default combo; the menus are the single
// dispatcher (`.keyboardShortcut(ShortcutBindings.shared[name])`), KeyboardShortcuts only stores the combos, so a
// rebinding updates the menu item at once and the old combo goes inert (known failure mode: no double fire).
import AntiChatDesign
import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

public extension KeyboardShortcuts.Name {
    static let newChat = Self("newChat", initial: .init(.n, modifiers: .command))
    static let newIncognito = Self("newIncognito", initial: .init(.n, modifiers: [.command, .shift]))
    static let newEvilChat = Self("newEvilChat", initial: .init(.e, modifiers: [.command, .shift]))
    static let palette = Self("palette", initial: .init(.k, modifiers: .command))
    static let findInChat = Self("findInChat", initial: .init(.f, modifiers: .command))
    static let back = Self("back", initial: .init(.leftBracket, modifiers: .command))
    static let forward = Self("forward", initial: .init(.rightBracket, modifiers: .command))
    static let toggleSidebar = Self("toggleSidebar", initial: .init(.s, modifiers: [.command, .shift]))
    static let shortcutList = Self("shortcutList", initial: .init(.slash, modifiers: .command))
    static let renameChat = Self("renameChat", initial: .init(.r, modifiers: [.command, .option]))
    static let pinChat = Self("pinChat", initial: .init(.p, modifiers: [.command, .option]))
    static let archiveChat = Self("archiveChat", initial: .init(.a, modifiers: [.command, .shift]))
    static let deleteChat = Self("deleteChat", initial: .init(.delete, modifiers: [.command, .shift]))
    static let copyLastCode = Self("copyLastCode", initial: .init(.semicolon, modifiers: [.command, .shift]))
}

/// Settings → Keyboard shortcuts groups (settings-map §12).
public enum ShortcutGroup: String, CaseIterable, Sendable {
    case composer, chat, app, global

    public var title: CopyKey { CopyKey("set.shortcuts.group.\(rawValue)") }
}

/// One row of the shortcut table: a rebindable name, or a fixed / not-yet-available entry.
public struct ShortcutEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Rebindable (KeyboardShortcuts.Recorder).
        case name(KeyboardShortcuts.Name)
        /// Fixed combo shown as text (composer keys follow Settings → General → Send with).
        case fixed(String)
        /// Arrives later (disabled with its reason).
        case later(String)
    }

    public var id: String
    public var group: ShortcutGroup
    public var label: CopyKey
    public var kind: Kind

    public var name: KeyboardShortcuts.Name? { if case .name(let n) = kind { n } else { nil } }
}

public enum ShortcutCatalog {
    /// Every entry, grouped Composer / Chat / App / Global (the Settings table and ⌘/ list read this; the
    /// generated-list test compares it with the names above).
    public static let entries: [ShortcutEntry] = [
        .init(id: "send", group: .composer, label: CopyKey("shortcut.send"), kind: .fixed("↩")),
        .init(id: "newline", group: .composer, label: CopyKey("shortcut.newline"), kind: .fixed("⇧↩")),
        .init(id: "copyLastCode", group: .composer, label: CopyKey("shortcut.copyLastCode"), kind: .name(.copyLastCode)),
        .init(id: "findInChat", group: .chat, label: CopyKey("shortcut.findInChat"), kind: .name(.findInChat)),
        .init(id: "renameChat", group: .chat, label: CopyKey("shortcut.renameChat"), kind: .name(.renameChat)),
        .init(id: "pinChat", group: .chat, label: CopyKey("shortcut.pinChat"), kind: .name(.pinChat)),
        .init(id: "archiveChat", group: .chat, label: CopyKey("shortcut.archiveChat"), kind: .name(.archiveChat)),
        .init(id: "deleteChat", group: .chat, label: CopyKey("shortcut.deleteChat"), kind: .name(.deleteChat)),
        .init(id: "newChat", group: .app, label: CopyKey("shortcut.newChat"), kind: .name(.newChat)),
        .init(id: "newIncognito", group: .app, label: CopyKey("shortcut.newIncognito"), kind: .name(.newIncognito)),
        .init(id: "newEvilChat", group: .app, label: CopyKey("shortcut.newEvilChat"), kind: .name(.newEvilChat)),
        .init(id: "palette", group: .app, label: CopyKey("shortcut.palette"), kind: .name(.palette)),
        .init(id: "back", group: .app, label: CopyKey("nav.back"), kind: .name(.back)),
        .init(id: "forward", group: .app, label: CopyKey("nav.forward"), kind: .name(.forward)),
        .init(id: "toggleSidebar", group: .app, label: CopyKey("shortcut.toggleSidebar"), kind: .name(.toggleSidebar)),
        .init(id: "shortcutList", group: .app, label: CopyKey("shortcut.shortcutList"), kind: .name(.shortcutList)),
        .init(id: "quickPanel", group: .global, label: CopyKey("shortcut.quickPanel"), kind: .name(.quickPanel)),  // M8.T13
        .init(id: "dictation", group: .global, label: CopyKey("shortcut.dictation"), kind: .later("")),
    ]

    public static var names: [KeyboardShortcuts.Name] { entries.compactMap(\.name) }

    public static func entries(in group: ShortcutGroup) -> [ShortcutEntry] { entries.filter { $0.group == group } }

    public static func entry(for name: KeyboardShortcuts.Name) -> ShortcutEntry? { entries.first { $0.name == name } }
}

/// The current combo of every name, observable: menus and the shortcut list re-render when one changes.
@MainActor
@Observable
public final class ShortcutBindings {
    public static let shared = ShortcutBindings()

    private(set) var version = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.version += 1
                Self.applyToMainMenu()
            }
        }
    }

    /// Re-keys the main menu's items at once (SwiftUI rebuilds them from `menuShortcut` on its next pass; this makes
    /// a rebinding effective immediately, the old combo inert).
    public static func applyToMainMenu(_ menu: NSMenu? = (NSApp as NSApplication?)?.mainMenu) {
        guard let menu else { return }
        var byTitle: [String: KeyboardShortcuts.Name] = [:]
        for e in ShortcutCatalog.entries { if let n = e.name { byTitle[e.label.string()] = n } }
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let name = byTitle[item.title] {
                    let s = ShortcutStore.get(name)
                    item.keyEquivalent = s?.nsMenuItemKeyEquivalent ?? ""
                    item.keyEquivalentModifierMask = s?.modifiers ?? []
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
    }

    /// The stored combo (or the default) of `name`.
    public func shortcut(_ name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        _ = version
        return ShortcutStore.get(name)
    }

    /// The SwiftUI key equivalent for a menu item (nil = unbound).
    public subscript(_ name: KeyboardShortcuts.Name) -> KeyboardShortcut? { shortcut(name)?.toSwiftUI }

    /// Display text, e.g. "⌘K".
    public func text(_ name: KeyboardShortcuts.Name) -> String { shortcut(name)?.description ?? "" }

    /// Settings → Keyboard shortcuts → Restore defaults.
    public func restoreDefaults() {
        ShortcutStore.reset(ShortcutCatalog.names)
        version += 1
        Self.applyToMainMenu()
    }
}
