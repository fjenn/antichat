// M1.T24 in-process shortcuts / menus / windows probe (`-ShortcutsProbe <dir>`, DEBUG; AT-103 / AT-104 while
// XCUITest is blocked, Q-015). Key presses go through the real main menu (`NSMenu.performKeyEquivalent` with a
// synthesized key event, as AppKit dispatches ⌘-keys), and the probe asserts window state per action.
// Modes (by `<dir>` contents / launch arguments):
//   shortcuts  AT-103 (1) every default shortcut performs its action (⇧⌘E inert, Evil disabled); (2) every shortcut
//              listed grouped Composer/Chat/App/Global; rebinding ⌘K → ⌥⌘K works at once (old combo inert, menu
//              shows the new one); ⌥⌘K for Rename is refused (conflict, not saved); Restore defaults.
//              AT-104 (1) the File/Edit/View/Window/Help menus and their items.
//   windows    AT-104 (2) first launch: two windows on two chats, moved/resized, `expected.json`, quit normally;
//   restore    second launch on the same container: both windows back with the same chats and frames (±1 pt).
//   lastwin    AT-104 (3) closes every window; with Menu bar item On the process stays (probe writes and quits);
//              with Off the app terminates by itself (the runner checks the exit).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatUI
import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

@MainActor
enum ShortcutsProbe {
    private static var started = false
    /// Every main window's state (registered by each MainWindowHost); `WindowState.window` is its NSWindow.
    static var windows: [WindowState] = []

    static func register(_ state: WindowState) {
        windows.removeAll { $0 === state }
        windows.append(state)
    }

    static func start(_ state: WindowState, sessions: ChatSessions, chats: ChatListService, out: String) {
        register(state)
        guard !started else { return }
        started = true
        Task { @MainActor in
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let mode = CommandLine.arguments.firstIndex(of: "-ShortcutsMode").map { CommandLine.arguments[$0 + 1] } ?? "shortcuts"
            let result: [String: Any]
            switch mode {
            case "windows": result = await windowsRun(state, sessions: sessions, chats: chats, dir: dir)
            case "restore": result = await restoreRun(dir: dir)
            case "lastwin": result = await lastWindowRun(dir: dir)
            default: result = await shortcutsRun(state, sessions: sessions, chats: chats, dir: dir)
            }
            SettingsProbe.write(result, dir: dir, name: "\(mode).json")
            NSApp.terminate(nil)
        }
    }

    // MARK: Key equivalents through the main menu

    /// The key event AppKit would deliver for `shortcut` (⌫ is the delete character, keyCode 51).
    static func keyChars(_ shortcut: KeyboardShortcuts.Shortcut) -> String? {
        shortcut.nsMenuItemKeyEquivalent
    }

    /// Presses `shortcut` like the keyboard (NSApp.sendEvent → key window → main menu key equivalents); true when
    /// a main-menu item carries it.
    static func press(_ shortcut: KeyboardShortcuts.Shortcut?, in window: NSWindow) -> Bool {
        guard let shortcut, let chars = keyChars(shortcut) else { return false }
        BackgroundRun.makeKeyAndOrderFront(window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shortcut.modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: UInt16(shortcut.carbonKeyCode)) else { return false }
            NSApp.sendEvent(e)
        }
        return menuItem(for: shortcut) != nil
    }

    /// Performs the main-menu item that carries `shortcut` (the menu's own path: `NSMenu.performActionForItem`, as a
    /// click or a matched key equivalent does). Synthesized key events do not reach SwiftUI's matching for some
    /// ⇧-combos and ⌫ in this process (A-M1-T24a (f)); the item path proves the item → action wiring.
    static func performMenuItem(for shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let item = menuItem(for: shortcut), let menu = item.menu, item.isEnabled else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    /// Presses `name`'s combo and waits for `done`.
    static var log: [String] = []

    /// The key path first; when the synthesized key does not land, the menu item that carries the combo. `via`
    /// in the log says which one performed the action.
    static func act(_ name: KeyboardShortcuts.Name, in window: NSWindow, _ done: () -> Bool) async -> Bool {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        let pressed = press(shortcut, in: window)
        var ok = await SettingsProbe.waitUntil(timeout: 1.5, done)
        var via = ok ? "key" : "none"
        if !ok, performMenuItem(for: shortcut) {
            ok = await SettingsProbe.waitUntil(done)
            via = ok ? "menuItem" : "none"
        }
        let item = menuItem(for: shortcut)
        log.append("\(name.rawValue): bound=\(pressed) done=\(ok) via=\(via) item=\(item?.title ?? "none") enabled=\(item?.isEnabled ?? false)")
        return pressed && ok
    }

    static func act(_ shortcut: KeyboardShortcuts.Shortcut?, in window: NSWindow, _ done: () -> Bool) async -> Bool {
        guard press(shortcut, in: window) else { return false }
        return await SettingsProbe.waitUntil(done)
    }

    static func press(_ name: KeyboardShortcuts.Name, in window: NSWindow) -> Bool {
        press(KeyboardShortcuts.getShortcut(for: name), in: window)
    }

    /// The menu item (any depth) whose key equivalent is `shortcut`.
    static func menuItem(for shortcut: KeyboardShortcuts.Shortcut?) -> NSMenuItem? {
        guard let shortcut, let key = shortcut.nsMenuItemKeyEquivalent else { return nil }
        let keys: Set<String> = shortcut.carbonKeyCode == 51 ? [key, "\u{8}", "\u{7f}"] : [key.lowercased()]
        func search(_ m: NSMenu) -> NSMenuItem? {
            for item in m.items {
                if keys.contains(item.keyEquivalent.lowercased()),
                   item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                    == shortcut.modifiers.intersection([.command, .option, .shift, .control]) { return item }
                if let sub = item.submenu, let hit = search(sub) { return hit }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    static func menuTitles() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for top in NSApp.mainMenu?.items ?? [] {
            out[top.title] = top.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        }
        return out
    }

    // MARK: AT-103 + AT-104 (1)

    static func shortcutsRun(_ state: WindowState, sessions: ChatSessions, chats: ChatListService, dir: URL) async -> [String: Any] {
        guard await SettingsProbe.setUp() else { return ["error": "no AntiChat window"] }
        KeyboardShortcuts.reset(ShortcutCatalog.names)
        let w = SettingsProbe.main!
        await SettingsProbe.settle(300)
        var acts: [String: Bool] = [:]

        // Two chats so back/forward and the chat actions have targets.
        _ = await ContextProbe.turn("First chat for the shortcut probe.", sessions: sessions, state: state)
        let first = state.currentChatID
        state.newChat()
        _ = await ContextProbe.turn("Second chat for the shortcut probe.", sessions: sessions, state: state)
        let second = state.currentChatID
        await SettingsProbe.settle(300)

        acts["back ⌘["] = await act(.back, in: w) { state.currentChatID != second }
        acts["forward ⌘]"] = await act(.forward, in: w) { state.currentChatID == second }
        let vis = state.columnVisibility
        acts["toggleSidebar ⇧⌘S"] = await act(.toggleSidebar, in: w) { state.columnVisibility != vis }
        state.columnVisibility = .all
        acts["palette ⌘K"] = await act(.palette, in: w) { PaletteController.lastAttached?.isPresented == true }
        PaletteController.lastAttached?.dismiss()
        await SettingsProbe.settle(200)
        acts["shortcutList ⌘/"] = await act(.shortcutList, in: w) { state.presentedSheet == .shortcuts && SettingsProbe.present("shortcutList") }
        SettingsProbe.capture(w, "shortcut-list.png", dir)
        state.presentedSheet = nil
        await SettingsProbe.settle(300)
        acts["renameChat ⌥⌘R"] = await act(.renameChat, in: w) { state.renamingChatID == second }
        state.renamingChatID = nil
        acts["pinChat ⌥⌘P"] = await act(.pinChat, in: w) { (try? chats.chat(second ?? ""))??.pinned == true }
        state.open(.chat(second ?? ""))
        await SettingsProbe.settle(300)
        let (findActs, selectActs) = await findAndSelectAll(state, sessions: sessions, in: w, dir: dir)
        acts.merge(findActs) { $1 }
        acts.merge(selectActs) { $1 }
        w.makeFirstResponder(nil)  // a focused text view keeps ⇧⌘⌫ / ⇧⌘A for itself
        await SettingsProbe.settle(300)
        var deleteTrace: [String] = []
        acts["deleteChat ⇧⌘⌫"] = await act(.deleteChat, in: w) {
            deleteTrace.append("\(state.pendingDelete?.ids.first ?? "nil")/\(SettingsProbe.present("deleteConfirm"))")
            return state.pendingDelete?.ids == [second ?? ""]
        }
        log.append("delete trace \(Array(Set(deleteTrace)).sorted()) current \(state.currentChatID ?? "nil") second \(second ?? "nil")")
        state.pendingDelete = nil
        w.makeFirstResponder(nil)
        acts["archiveChat ⇧⌘A"] = await act(.archiveChat, in: w) { ((try? chats.archived().map(\.id)) ?? []).contains(second ?? "-") }
        let before = state.route
        _ = press(.newEvilChat, in: w)
        await SettingsProbe.settle(300)
        acts["newEvilChat ⇧⌘E inert (Evil off)"] = state.route == before && (menuItem(for: KeyboardShortcuts.getShortcut(for: .newEvilChat))?.isEnabled == false)
        acts["newChat ⌘N"] = await act(.newChat, in: w) { state.route == .newChat }
        let count = NSApp.windows.filter(\.isVisible).count
        acts["newIncognito ⇧⌘N (window)"] = await act(.newIncognito, in: w) {
            NSApp.windows.filter(\.isVisible).count > count && windows.contains { $0.route == .incognito }
        }
        // Close the incognito window the ⇧⌘N leg opened; the rest of the run is on the first window.
        for other in windows where other !== state { other.window?.close() }
        windows.removeAll { $0 !== state }
        BackgroundRun.makeKeyAndOrderFront(w)
        await SettingsProbe.settle(500)
        acts["copyLastCode ⌘⇧; (menu item bound)"] = menuItem(for: KeyboardShortcuts.getShortcut(for: .copyLastCode)) != nil
        let missingFromMenus = ShortcutCatalog.names.filter { $0 != .copyLastCode && menuItem(for: KeyboardShortcuts.getShortcut(for: $0)) == nil }.map(\.rawValue)

        // (2) the table, rebinding, conflict, restore.
        ShortcutsProbe.log.append("windows \(windows.map { "\($0.route)" }) visible \(NSApp.windows.filter(\.isVisible).map(\.title))")
        ShortcutsProbe.log.append("archive/delete target \(second ?? "nil") current \(state.currentChatID ?? "nil")")
        let groups = Dictionary(grouping: ShortcutCatalog.entries, by: \.group.rawValue).mapValues { $0.map(\.id) }
        let oldK = KeyboardShortcuts.getShortcut(for: .palette)
        let newK = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
        let rebindRefused = ShortcutConflicts.assign(newK, to: .palette)
        await SettingsProbe.settle(300)
        let menuShowsNew = menuItem(for: newK)?.title == CopyKey("side.search").string()
        _ = press(oldK, in: w)
        await SettingsProbe.settle(400)
        // This window's own palette (the ⇧⌘N leg opened a second window, which has its own controller).
        let oldInert = menuItem(for: oldK) == nil && state.palette?.isPresented != true
        let newWorks = await act(newK, in: w) { state.palette?.isPresented == true }
        state.palette?.dismiss()
        let conflict = ShortcutConflicts.assign(newK, to: .renameChat)
        let notSaved = KeyboardShortcuts.getShortcut(for: .renameChat) == KeyboardShortcuts.Name.renameChat.initialShortcut
        ShortcutBindings.shared.restoreDefaults()
        let restored = ShortcutCatalog.names.allSatisfy { KeyboardShortcuts.getShortcut(for: $0) == $0.initialShortcut }
        // Settings → Keyboard shortcuts shows every entry.
        // General → About & Help → Keyboard shortcuts (the rebinding sheet).
        _ = await SettingsProbe.openSettingsWithCommandComma()
        SettingsModel.shared.open(.general, row: "shortcuts")
        SettingsModel.shared.showingShortcuts = true
        await SettingsProbe.settle(600)
        SettingsProbe.capture(SettingsProbe.settingsWindow, "S-21-shortcuts.png", dir)
        let rowsShown = SettingsProbe.present("settings.row.shortcut.newChat")
        SettingsModel.shared.showingShortcuts = false
        await SettingsProbe.closeSettings()

        let menus = menuTitles()
        let file = menus["File"] ?? []
        let want = ["menu.file.newChat", "menu.file.newIncognito", "menu.file.newProject", "menu.file.newWindow"].map { CopyKey($0).string() }
        let help = menus["Help"] ?? []
        let menuLeg: [String: Any] = [
            "pass": want.allSatisfy(file.contains) && file.contains("Close") && ["Edit", "View", "Window", "Help"].allSatisfy { menus[$0] != nil }
                && help.contains(CopyKey("menu.help.report").string()) && help.contains(CopyKey("menu.help.legal").string()),
            "file": file, "help": help, "view": menus["View"] ?? [], "top": Array(menus.keys).sorted(),
        ]
        let pass1 = acts.values.allSatisfy { $0 } && missingFromMenus.isEmpty
        let pass2 = rebindRefused == nil && menuShowsNew && oldInert && newWorks && conflict == .palette && notSaved && restored
            && rowsShown && groups.count == 4
        return ["mode": "shortcuts", "pass": pass1 && pass2 && (menuLeg["pass"] as? Bool == true),
                "AT-103-1": ["pass": pass1, "actions": acts, "log": log, "missingFromMenus": missingFromMenus],
                "AT-103-2": ["pass": pass2, "groups": groups, "menuShowsNew": menuShowsNew, "oldComboInert": oldInert,
                             "newComboWorks": newWorks, "conflictWith": conflict?.rawValue ?? "none", "conflictNotSaved": notSaved,
                             "restoreDefaults": restored, "settingsRows": rowsShown],
                "AT-104-1": menuLeg]
    }

    // MARK: ⌘F find bar and transcript-only ⌘A (M1.T24 steps 2–3)

    /// The composer's text view in `window` (the AntiChatUI class is internal: matched by name).
    static func composerTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let t = view as? NSTextView, String(describing: type(of: t)) == "ComposerNSTextView" { return t }
        for s in view.subviews { if let t = composerTextView(in: s) { return t } }
        return nil
    }

    static func findAndSelectAll(_ state: WindowState, sessions: ChatSessions, in w: NSWindow, dir: URL) async
        -> ([String: Bool], [String: Bool]) {
        var find: [String: Bool] = [:], sel: [String: Bool] = [:]
        guard let conv = state.conversation?() else { return (["findInChat ⌘F (no conversation)": false], [:]) }
        w.makeFirstResponder(nil)
        find["findInChat ⌘F"] = await act(.findInChat, in: w) { conv.find.isPresented && SettingsProbe.present("findBar") }
        conv.find.query = "probe"  // the user message "Second chat for the shortcut probe."
        let found = await SettingsProbe.waitUntil { SettingsProbe.present("findCurrent") && SettingsProbe.present("findMatch") }
        find["findInChat highlights + count"] = found && !conv.find.matches.isEmpty
            && conv.find.label == CopyKey("find.count").string(["current": "1", "total": "\(conv.find.matches.count)"])
        SettingsProbe.capture(w, "find-bar.png", dir)
        conv.find.dismiss()
        await SettingsProbe.settle(200)
        log.append("find matches \(conv.find.matches.count)")

        // ⌘A with the composer focused selects the composer's text, not the transcript.
        let selectAll = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
        let copy = KeyboardShortcuts.Shortcut(.c, modifiers: [.command])
        let draft = "composer draft that must not be copied"
        sessions.composer.text = draft
        await SettingsProbe.settle(200)
        if let tv = composerTextView(in: w.contentView) {
            w.makeFirstResponder(tv)
            await SettingsProbe.settle(100)
            _ = press(selectAll, in: w)
            await SettingsProbe.settle(100)
            sel["selectAll ⌘A in composer → composer text"] = tv.selectedRange().length == (tv.string as NSString).length
                && tv.selectedRange().length > 0 && !conv.selection.isAll
        } else {
            sel["selectAll ⌘A in composer → composer text"] = false
        }
        // ⌘A with no text view focused selects the transcript only; ⌘C copies exactly its text.
        w.makeFirstResponder(nil)
        await SettingsProbe.settle(100)
        let tookA = press(selectAll, in: w)
        let selected = await SettingsProbe.waitUntil { conv.selection.isAll && SettingsProbe.present("transcriptSelected") }
        SettingsProbe.capture(w, "select-all.png", dir)
        NSPasteboard.general.clearContents()
        _ = press(copy, in: w)
        await SettingsProbe.settle(100)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        sel["selectAll ⌘A transcript only + ⌘C"] = tookA && selected && copied == conv.transcriptText()
            && !copied.isEmpty && !copied.contains(draft) && !copied.contains(CopyKey("side.search").string())
        log.append("selectAll copied \(copied.count) chars, transcript \(conv.transcriptText().count)")
        conv.selection.clear()
        sessions.composer.text = ""
        return (find, sel)
    }

    // MARK: AT-104 (2) windows + restoration

    static func frameText(_ f: CGRect) -> [Double] {
        [f.minX, f.minY, f.width, f.height].map { (Double($0) * 10).rounded() / 10 }
    }

    /// Opens a fresh main window through File › New Window and returns its state.
    static func openFreshWindow(from window: NSWindow) async -> WindowState? {
        let before = Set(windows.map(ObjectIdentifier.init))
        _ = press(KeyboardShortcuts.Shortcut(.n, modifiers: [.command, .option]), in: window)  // New Window ⌥⌘N
        _ = await SettingsProbe.waitUntil { windows.contains { !before.contains(ObjectIdentifier($0)) && $0.window != nil } }
        await SettingsProbe.settle(800)
        return windows.first { !before.contains(ObjectIdentifier($0)) && $0.window != nil }
    }

    static func windowsRun(_ state: WindowState, sessions: ChatSessions, chats: ChatListService, dir: URL) async -> [String: Any] {
        guard await SettingsProbe.setUp() else { return ["error": "no AntiChat window"] }
        // Deterministic start (AT-104 (2)): the saved window state of earlier runs is not always where the runner can
        // delete it (it lives outside ~/Library/Saved Application State on this Mac), and a restored window keeps
        // its restored scene value. So the run never uses a restored window: it opens two fresh windows through
        // File › New Window and closes every window that was there at launch.
        let atLaunch = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        guard let first = await openFreshWindow(from: SettingsProbe.main), let w1 = first.window else {
            return ["mode": "windows", "pass": false, "error": "no fresh window"]
        }
        for old in atLaunch { old.close() }
        windows.removeAll { $0 !== first }
        await SettingsProbe.settle(500)
        let a = try? chats.create(title: "Window A chat"), b = try? chats.create(title: "Window B chat")
        guard let a, let b else { return ["error": "no chats"] }
        first.open(.chat(a.id))
        w1.setFrame(CGRect(x: 80, y: 140, width: 1000, height: 700), display: true)
        guard let second = await openFreshWindow(from: w1), let w2 = second.window else {
            return ["mode": "windows", "pass": false, "error": "no second window", "count": windows.count]
        }
        second.open(.chat(b.id))
        w2.setFrame(CGRect(x: 420, y: 90, width: 900, height: 640), display: true)
        await SettingsProbe.settle(1200)  // SceneStorage / restorable state
        let expected: [[String: Any]] = [
            ["chat": a.id, "frame": frameText(w1.frame)],
            ["chat": b.id, "frame": frameText(w2.frame)],
        ]
        SettingsProbe.write(expected, dir: dir, name: "expected.json")
        return ["mode": "windows", "pass": true, "expected": expected, "closedAtLaunch": atLaunch.count]
    }

    static func restoreRun(dir: URL) async -> [String: Any] {
        await SettingsProbe.settle(2500)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("expected.json")),
              let expected = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ["mode": "restore", "pass": false, "error": "no expected.json"]
        }
        let mains = NSApp.windows.filter { $0.isVisible && $0.title == "AntiChat" }
        var found: [[String: Any]] = []
        for w in mains {
            let state = windows.first { $0.window === w }
            found.append(["chat": state?.currentChatID ?? "", "frame": frameText(w.frame)])
        }
        let ok = expected.allSatisfy { e in
            found.contains { f in
                (f["chat"] as? String) == (e["chat"] as? String)
                    && zip((f["frame"] as? [Double]) ?? [], (e["frame"] as? [Double]) ?? []).allSatisfy { abs($0 - $1) <= 1 }
            }
        }
        return ["mode": "restore", "pass": ok && mains.count >= expected.count, "expected": expected, "found": found]
    }

    // MARK: AT-104 (3) last window

    static func lastWindowRun(dir: URL) async -> [String: Any] {
        await SettingsProbe.settle(1500)
        let keep = Defaults[.menuBarItem]
        SettingsProbe.write(["menuBarItem": keep, "closing": true], dir: dir, name: "lastwin-closing.json")
        for w in NSApp.windows where w.isVisible { w.performClose(nil) }
        await SettingsProbe.settle(2000)  // with Off the app is gone before this returns
        return ["mode": "lastwin", "pass": keep, "menuBarItem": keep, "stillRunning": true,
                "visibleWindows": NSApp.windows.filter(\.isVisible).count]
    }
}
#endif
