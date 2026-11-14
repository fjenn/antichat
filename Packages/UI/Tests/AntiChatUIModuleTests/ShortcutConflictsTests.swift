// M1.T24 (AT-103 unit leg; R-103): the default list, the generated shortcut table (Settings and ⌘/ list read
// ShortcutCatalog, which must hold every name exactly once in the four groups), and in-app collision detection.
import AppKit
import KeyboardShortcuts
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct ShortcutConflictsTests {
    typealias S = KeyboardShortcuts.Shortcut

    @Test func defaultsMatchR103() {
        let want: [KeyboardShortcuts.Name: S] = [
            .newChat: S(.n, modifiers: .command), .newIncognito: S(.n, modifiers: [.command, .shift]),
            .palette: S(.k, modifiers: .command), .findInChat: S(.f, modifiers: .command),
            .back: S(.leftBracket, modifiers: .command), .forward: S(.rightBracket, modifiers: .command),
            .toggleSidebar: S(.s, modifiers: [.command, .shift]), .shortcutList: S(.slash, modifiers: .command),
            .renameChat: S(.r, modifiers: [.command, .option]), .pinChat: S(.p, modifiers: [.command, .option]),
            .archiveChat: S(.a, modifiers: [.command, .shift]), .deleteChat: S(.delete, modifiers: [.command, .shift]),
            .newEvilChat: S(.e, modifiers: [.command, .shift]), .copyLastCode: S(.semicolon, modifiers: [.command, .shift]),
            .quickPanel: S(.space, modifiers: .option),  // M8.T13 (R-106): the global quick panel
        ]
        for (name, s) in want { #expect(name.initialShortcut == s, "\(name.rawValue)") }
        #expect(Set(ShortcutCatalog.names) == Set(want.keys))
    }

    @Test func tableListsEveryShortcutOnceInFourGroups() {
        let names = ShortcutCatalog.names.map(\.rawValue)
        #expect(names.count == Set(names).count)
        #expect(Set(ShortcutCatalog.entries.map(\.group)) == Set(ShortcutGroup.allCases))
        // Global: the quick panel is rebindable (M8.T13); system-wide dictation stays "later" (M11).
        #expect(ShortcutCatalog.entries(in: .global).map(\.id) == ["quickPanel", "dictation"])
        #expect(ShortcutCatalog.entries(in: .global).first?.name == .quickPanel)
        #expect({ if case .later = ShortcutCatalog.entries(in: .global).last?.kind { true } else { false } }())
        // No two defaults collide.
        let defaults = ShortcutCatalog.names.compactMap(\.initialShortcut)
        #expect(defaults.count == Set(defaults).count)
    }

    @Test func collisionIsRefusedAndNotSaved() {
        var store: [KeyboardShortcuts.Name: S] = Dictionary(uniqueKeysWithValues: ShortcutCatalog.names.compactMap { n in
            n.initialShortcut.map { (n, $0) }
        })
        let optK = S(.k, modifiers: [.command, .option])
        store[.palette] = optK  // ⌘K rebound to ⌥⌘K
        #expect(ShortcutConflicts.conflict(for: optK, assigningTo: .renameChat, current: { store[$0] }) == .palette)
        #expect(ShortcutConflicts.conflict(for: optK, assigningTo: .palette, current: { store[$0] }) == nil)
        #expect(ShortcutConflicts.conflict(for: S(.k, modifiers: .command), assigningTo: .renameChat,
                                           current: { store[$0] }) == nil)  // the old combo is free again
    }
}
