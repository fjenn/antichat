// AT-013 in-process menus probe (M1.T17). XCUITest is blocked on this Mac (Q-015), so — like WindowProbe /
// PaletteProbe / ContextProbe — the app drives its own window with real key and mouse events (NSApp.sendEvent to the
// composer's NSTextView, mouse events on the probe anchors) and records what is on screen:
//   (1) the + menu (click `composerAdd`): every row, enabled or with its disabled reason; a row whose pack is
//       installed but off is clicked and must open Settings;
//   (2) `/` at the start and `@` mid-text open the same list; typing filters it; ↓ from the last row wraps to the
//       first and ↑ from the first to the last; Esc closes; `/` mid-text does not open it;
//   (3) when the active model takes tools: `@ech` + Return and `/wri` + Return add two chips, a sent message keeps
//       both (on screen and in `chat.tools_json`), and × removes one;
//   relaunch: a launch on a container that already holds the chat opens it and records which chips are shown
//   (the removed one must stay removed, the other must come back; none at all while the starter is active, D-023).
// Writes `<dir>/probe.json` (+ window captures) and quits. DEBUG only (`-MenusProbe <dir>`); run by
// tools/at/at-013-probe.sh.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum MenusProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("MenusProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    // MARK: Helpers

    static func write(_ obj: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }

    /// The window (main window or a popover) holding a live anchor `id`, and its frame there.
    static func anchor(_ id: String) -> (NSWindow, CGRect)? {
        for w in NSApp.windows where w.isVisible {
            if let f = UIProbeRegistry.frame(id, in: w) { return (w, f) }
        }
        return nil
    }

    static func present(_ id: String) -> Bool { anchor(id) != nil }

    @discardableResult
    static func click(_ id: String) -> Bool {
        guard let (w, f) = anchor(id) else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            w.sendEvent(e)
        }
        return true
    }

    static func up() { PaletteProbe.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126, flags: [.numericPad, .function]) }
    static func down() { PaletteProbe.down() }

    static func textView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.accessibilityIdentifier() == "composerText" { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// Clears the composer and gives it keyboard focus.
    static func resetComposer(_ composer: ComposerModel, window: NSWindow) async {
        composer.text = ""
        await PaletteProbe.settle(150)
        if let tv = window.contentView.flatMap(textView(in:)) { window.makeFirstResponder(tv) }
        await PaletteProbe.settle(100)
    }

    static func capture(_ name: String, _ dir: URL, window: NSWindow) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", dir.appendingPathComponent(name).path]
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    static func onScreenChips() -> [String] { UIProbeRegistry.ids(prefix: "toolChip.", in: PaletteProbe.window) }

    static func storedChips(_ env: ChatEnvironment, _ chatID: String?) -> [String] {
        guard let chatID else { return [] }
        return ToolChipsModel.decode((try? ChatRepository(env.database).toolsJSON(chatID)) ?? nil)
    }

    // MARK: Run

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(1500))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) else {
            write(["error": "no AntiChat window"], dir: dir)
            return
        }
        PaletteProbe.window = window
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        BackgroundRun.makeKeyAndOrderFront(window)
        BackgroundRun.activate()
        await PaletteProbe.settle(800)
        let env = sessions.environment
        let composer = sessions.composer
        let menus = composer.menus
        let o = LaunchOptions.current
        var result: [String: Any] = [
            "activeModel": env.slot().key, "offersTools": menus.context.offersTools,
            "installedPacks": menus.context.installedPacks.sorted(), "disabledPacks": menus.context.disabledPacks.sorted(),
            "webSearchEnabled": o.fakeWebSearchEnabled, "connectionsEnabled": o.fakeConnectionsEnabled,
            "registryTools": menus.context.tools.map(\.name),
        ]

        // Relaunch: the container already holds the chat of the first launch.
        if let chat = try? ChatRepository(env.database).sidebar(limit: 1).first {
            state.open(.chat(chat.id))
            _ = await PaletteProbe.waitUntil(timeout: 5) { sessions.currentChatID == chat.id }
            await PaletteProbe.settle(800)
            capture("relaunch.png", dir, window: window)
            result["phase"] = "relaunch"
            result["relaunch"] = ["chatID": chat.id, "chipsOnScreen": onScreenChips(), "chipsShown": menus.chips.chips.map(\.id),
                                  "chipsStored": storedChips(env, chat.id)]
            write(result, dir: dir)
            return
        }
        result["phase"] = "first"

        // (1) + menu.
        await resetComposer(composer, window: window)
        click("composerAdd")
        let opened = await PaletteProbe.waitUntil(timeout: 3) { present("addMenu") } != nil
        await PaletteProbe.settle(300)
        if let (pw, _) = anchor("addMenu") { capture("add-menu.png", dir, window: pw) }
        let rows: [[String: Any]] = menus.addItems.map { item in
            ["id": item.id, "title": ComposerMenus.title(item), "enabled": item.state.isEnabled,
             "reason": ComposerMenus.reason(item.state)?.string ?? "", "onScreen": present("addRow.\(item.id)")]
        }
        var settingsOpened = 0
        let enableRow = menus.addItems.first { if case .needsEnable = $0.state { true } else { false } }
        if let row = enableRow {
            let original = menus.openSettings
            menus.openSettings = { settingsOpened += 1; original?() }
            click("addRow.\(row.id)")
            await PaletteProbe.settle(500)
            for w in NSApp.windows where w.isVisible && w !== window && w.title != "AntiChat" && !(w is NSPanel) {
                w.close()  // the Settings window it opened
            }
            menus.openSettings = original
        }
        menus.isAddMenuOpen = false
        await PaletteProbe.settle(300)
        result["leg1"] = ["menuOpened": opened, "rows": rows, "enableRowClicked": enableRow?.id ?? "",
                          "settingsOpened": settingsOpened]

        // (2) Triggers, filter, wrap, Esc, `/` mid-text.
        await resetComposer(composer, window: window)
        await PaletteProbe.type("/")
        let slashOpen = await PaletteProbe.waitUntil(timeout: 2) { present("slashAtMenu") } != nil
        let slashList = menus.inlineItems.map(\.id)
        let slashRows = slashList.filter { present("menuRow.\($0)") }.count
        capture("slash-open.png", dir, window: window)
        up()
        await PaletteProbe.settle(80)
        let upFromFirst = menus.selection  // ↑ on the first row (selection starts at 0)
        down()
        await PaletteProbe.settle(80)
        let wrapToFirst = menus.selection  // ↓ on the last row
        var walk: [Int] = []  // ↓ through the whole list once more: 1 … n-1, 0
        for _ in 0..<slashList.count { down(); await PaletteProbe.settle(30); walk.append(menus.selection) }
        PaletteProbe.escape()
        await PaletteProbe.settle(150)
        let escClosed = !present("slashAtMenu") && !menus.isInlineOpen

        await resetComposer(composer, window: window)
        await PaletteProbe.type("hello @")
        let atOpen = await PaletteProbe.waitUntil(timeout: 2) { present("slashAtMenu") } != nil
        let atList = menus.inlineItems.map(\.id)
        let filterQuery = menus.context.offersTools && menus.context.tools.contains { $0.name == "echo" } ? "ech" : "vid"
        await PaletteProbe.type(filterQuery)
        await PaletteProbe.settle(150)
        let filtered = menus.inlineItems.map(\.id)
        capture("at-filtered.png", dir, window: window)
        await PaletteProbe.type("zzqx")
        await PaletteProbe.settle(150)
        let emptyShown = present("menuEmpty")
        capture("at-empty.png", dir, window: window)

        await resetComposer(composer, window: window)
        await PaletteProbe.type("hello /")
        await PaletteProbe.settle(250)
        let slashMidOpen = present("slashAtMenu") || menus.isInlineOpen
        await resetComposer(composer, window: window)

        result["leg2"] = [
            "slashOpened": slashOpen, "slashList": slashList, "slashRowsOnScreen": slashRows,
            "atOpened": atOpen, "atList": atList, "sameList": slashList == atList && !slashList.isEmpty,
            "filterQuery": filterQuery, "filtered": filtered,
            "filters": !filtered.isEmpty && filtered.count < atList.count,
            "upFromFirst": upFromFirst, "downFromLast": wrapToFirst, "walk": walk, "count": slashList.count,
            "wraps": upFromFirst == slashList.count - 1 && wrapToFirst == 0
                && walk == Array(1..<max(1, slashList.count)) + [0],
            "escCloses": escClosed, "noMatchesShown": emptyShown, "slashMidTextOpens": slashMidOpen,
        ]

        // (3) Chips (only when the active model takes tools and the scripted tools are registered).
        guard menus.context.offersTools, menus.context.tools.contains(where: { $0.name == "echo" }),
              menus.context.tools.contains(where: { $0.name == "write_note" }) else {
            result["leg3"] = ["skipped": "no tool entries for \(env.slot().key) (D-023) or no -UseScriptedTools",
                              "chipsOnScreen": onScreenChips()]
            write(result, dir: dir)
            return
        }
        await PaletteProbe.type("@ech")
        await PaletteProbe.settle(150)
        PaletteProbe.returnKey()
        await PaletteProbe.settle(250)
        await PaletteProbe.type("/wri")
        await PaletteProbe.settle(150)
        PaletteProbe.returnKey()
        await PaletteProbe.settle(300)
        let afterPick = onScreenChips()
        let textAfterPick = composer.text
        capture("chips.png", dir, window: window)

        await PaletteProbe.type("first message")
        PaletteProbe.returnKey()
        let replied = await PaletteProbe.waitUntil(timeout: 30) {
            guard let m = state.currentChatID.map(sessions.model(for:)) else { return false }
            return !m.isGenerating && m.messages.last?.role == .assistant && m.messages.last?.status == .done
        } != nil
        await PaletteProbe.settle(800)
        let chatID = state.currentChatID
        let afterSend = onScreenChips()
        let storedAfterSend = storedChips(env, chatID)
        capture("chips-after-send.png", dir, window: window)

        let removed = click("toolChipRemove.tool:echo")
        await PaletteProbe.settle(400)
        let afterRemove = onScreenChips()
        let storedAfterRemove = storedChips(env, chatID)
        capture("chip-removed.png", dir, window: window)

        result["leg3"] = [
            "chipsAfterPick": afterPick, "textAfterPick": textAfterPick, "sendReplied": replied, "chatID": chatID ?? "",
            "chipsAfterSend": afterSend, "storedAfterSend": storedAfterSend, "removeClicked": removed,
            "chipsAfterRemove": afterRemove, "storedAfterRemove": storedAfterRemove,
        ]
        write(result, dir: dir)
        FileHandle.standardError.write(Data("MenusProbe: done\n".utf8))
    }
}
#endif
