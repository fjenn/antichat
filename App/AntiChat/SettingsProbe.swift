// M1.T22 in-process Settings probe (`-SettingsProbe <dir>`, DEBUG). XCUITest is blocked on this Mac (Q-015), so —
// like WindowProbe / PaletteProbe / ContextProbe — the app drives itself through its real windows with AppKit
// events (keys to the key window, mouse clicks at probe anchors) and records:
//   AT-100 (1) ⌘, opens Settings; the 13 nav items in order; the search field (typed) and every registered row
//          found by its label; (2) every enabled M1 row changed once (toggles and segmented controls clicked, text
//          areas typed, menu pickers set through their key) and read back from Defaults with no Apply — and, in the
//          second launch on the same <dir>, after relaunch; (3) the sidebar footer menu: Settings, Help, Report a bug,
//          Check for updates, each opening its target; (4) Capabilities → Advanced collapsed by default.
//   AT-062 (1) the 3,001st character is refused; the prompt of a new Normal / Evil / incognito turn (2).
//   AT-011 (4) Archived chats: list, search, Unarchive, Delete; Archive all; Delete all only after typing DELETE;
//          Auto-archive default Never.
//   AT-012 (2) ⌘K → "send with" → Return opens Settings at the "Send with" row (forward leg from M1.T11).
//   AT-002 (4)–(5), AT-009 (1) through the UI (the composer reads the toggled settings; the context indicator shows
//          after a turn) and, in the `-showContextUsage YES …` launch, through the launch arguments (step 8).
// Modes: `<dir>/written.json` present → "relaunch" (verify only); `-showContextUsage` among the arguments →
// "launchargs"; otherwise the full run. Writes `<dir>/probe.json` (+ window captures) and quits.
// Run by tools/at/at-100-probe.sh with `-DefaultsSuite` (the developer's own settings are never touched).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatUI
import AppKit
import Defaults
import SwiftUI

@MainActor
enum SettingsProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, chats: ChatListService, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("SettingsProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let result: [String: Any]
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("written.json").path) {
                result = await relaunch(dir)
            } else if CommandLine.arguments.contains("-showContextUsage") {
                result = await launchArguments(state, sessions: sessions, dir: dir)
            } else {
                result = await run(state, sessions: sessions, chats: chats, dir: dir)
            }
            write(result, dir: dir, name: "probe.json")
            NSApp.terminate(nil)
        }
    }

    // MARK: Helpers

    static var main: NSWindow!
    static let model = SettingsModel.shared

    static func write(_ obj: Any, dir: URL, name: String) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name))
        }
    }

    static func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    static func waitUntil(timeout: Double = 3, _ cond: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while true {
            if cond() { return true }
            if PaletteProbe.seconds(ContinuousClock.now - start) > timeout { return false }
            await settle(10)
        }
    }

    /// The visible window holding an anchor with `id` (main window, Settings window, a sheet or a popover).
    static func window(with id: String) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && UIProbeRegistry.frame(id, in: $0) != nil }
    }

    static func present(_ id: String) -> Bool { window(with: id) != nil }

    static var settingsWindow: NSWindow? { window(with: "settings.root") }

    /// Clicks the anchor `id` at `fraction` of its width (segmented controls), wherever it is on screen.
    @discardableResult
    static func click(_ id: String, at fraction: CGFloat = 0.5, tracking: Bool = true, in target: NSWindow? = nil) -> Bool {
        guard let w = target ?? window(with: id), let f = UIProbeRegistry.frame(id, in: w) else { return false }
        let p = CGPoint(x: f.minX + f.width * fraction, y: f.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        // An AppKit control (NSSwitch, NSSegmentedControl) runs a tracking loop inside mouseDown that pulls the
        // mouseUp from the queue: queue it first, then deliver the mouseDown.
        // AppKit controls and text views (NSSwitch, NSSegmentedControl, NSTextView) track inside mouseDown and pull
        // the mouseUp from the queue, so it is queued first; `tracking: false` delivers both directly (SwiftUI
        // buttons only).
        if tracking {
            NSApp.postEvent(up, atStart: false)
            w.sendEvent(down)
        } else {
            w.sendEvent(down)
            w.sendEvent(up)
        }
        return true
    }

    /// Key presses into `window` (its first responder), like the keyboard.
    static func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.sendEvent(e)
        }
    }

    static func type(_ text: String, in window: NSWindow) async {
        for ch in text {
            key(String(ch), code: ch == " " ? 49 : 0, in: window)
            await settle(8)
        }
    }

    static func capture(_ window: NSWindow?, _ name: String, _ dir: URL) {
        guard let window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", dir.appendingPathComponent(name).path]
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    /// Clicks a button and waits for `done`; a SwiftUI-hosted NSButton sometimes needs the tracking delivery, so
    /// the second try uses it.
    @discardableResult
    static func press(_ id: String, until done: () -> Bool) async -> Bool {
        for tracking in [false, true] {
            await settle(150)
            click(id, tracking: tracking)
            if await waitUntil(timeout: 1.5, done) { return true }
        }
        return false
    }

    /// Scrolls the Settings detail to row `row` of `section` (the ⌘K reveal path) so its control is on screen.
    static func reveal(_ row: String, in section: SettingsSection, control: String) async -> Bool {
        model.open(section, row: row)
        return await waitUntil { present(control) }
    }

    /// Focuses the NSTextView under the anchor `id` (a click on a TextEditor, then first responder by hit test).
    static func focusText(_ id: String) async -> Bool {
        click(id, at: 0.3, tracking: true)  // NSTextView tracks the selection until the mouseUp
        await settle(150)
        guard let w = window(with: id), let f = UIProbeRegistry.frame(id, in: w) else { return false }
        func textViews(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
        guard let content = w.contentView,
              let tv = textViews(content).first(where: { $0.convert($0.visibleRect, to: nil).intersects(f) }) else { return false }
        return w.firstResponder === tv || w.makeFirstResponder(tv)
    }

    static func openSection(_ s: SettingsSection) async -> Bool {
        click("settings.nav.\(s.rawValue)")
        return await waitUntil { model.selection == s && present("settings.detail.\(s.rawValue)") }
    }

    /// Opens Settings with ⌘, (the app menu's key equivalent); falls back to the menu action.
    static func openSettingsWithCommandComma() async -> String {
        BackgroundRun.makeKeyAndOrderFront(main)
        await settle(150)
        key(",", code: 43, flags: .command, in: main)
        if await waitUntil(timeout: 2, { settingsWindow != nil }) { return "commandComma" }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        return await waitUntil(timeout: 2, { settingsWindow != nil }) ? "menuAction-fallback" : "failed"
    }

    static func closeSettings() async {
        settingsWindow?.performClose(nil)
        _ = await waitUntil { settingsWindow == nil }
    }

    /// Every Settings key's value, as JSON-able text.
    static func values() -> [String: String] {
        [
            "sendWithCommandEnter": "\(Defaults[.sendWithCommandEnter])",
            "plainTextComposer": "\(Defaults[.plainTextComposer])",
            "showContextUsage": "\(Defaults[.showContextUsage])",
            "launchAtLogin": "\(Defaults[.launchAtLogin])",
            "menuBarItem": "\(Defaults[.menuBarItem])",
            "showModelInfo": "\(Defaults[.showModelInfo])",
            "aboutYou": Defaults[.aboutYou],
            "howToRespond": Defaults[.howToRespond],
            "stylePreset": Defaults[.stylePreset],
            "warmth": Defaults[.warmth],
            "enthusiasm": Defaults[.enthusiasm],
            "headersAndLists": Defaults[.headersAndLists],
            "emoji": Defaults[.emoji],
            "autoArchiveDays": "\(Defaults[.autoArchiveDays])",
        ]
    }

    static func setUp() async -> Bool {
        await settle(1500)
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) else { return false }
        main = w
        PaletteProbe.window = w
        BackgroundRun.activate()
        BackgroundRun.makeKeyAndOrderFront(main)
        main.setFrame(CGRect(x: 60, y: 120, width: 1180, height: 820), display: true)
        await settle(400)
        return true
    }

    // MARK: Full run

    static func run(_ state: WindowState, sessions: ChatSessions, chats: ChatListService, dir: URL) async -> [String: Any] {
        guard await setUp() else { return ["error": "no AntiChat window"] }
        guard UserDefaults.antichatIsIsolated else { return ["error": "refusing to run without -DefaultsSuite"] }
        SettingsKeys.resetAll()
        var legs: [String: [String: Any]] = [:]
        let defaultsBefore = values()

        // AT-100 (1): ⌘, opens Settings; nav order; search.
        let opened = await openSettingsWithCommandComma()
        await settle(600)
        settingsWindow?.setFrameOrigin(CGPoint(x: 260, y: 160))
        var navOrder: [String] = []
        if let sw = settingsWindow {
            navOrder = SettingsSection.allCases
                .compactMap { s in UIProbeRegistry.frame("settings.nav.\(s.rawValue)", in: sw).map { (s, $0) } }
                .sorted { $0.1.maxY > $1.1.maxY }
                .map { $0.0.title.string() }
        }
        let expectedNav = ["General", "Appearance", "Capabilities", "Evil Mode", "Voice", "Personalization",
                           "Tools & Connections", "Skills", "Privacy & Data", "Storage", "Updates",
                           "Keyboard shortcuts", "About & Help"]
        capture(settingsWindow, "S-21-general.png", dir)
        // Typed search (real keystrokes into the field).
        var typedOK = false
        if let sw = settingsWindow {
            click("settings.search")
            await settle(200)
            await type("send with", in: sw)
            typedOK = await waitUntil { model.query == "send with" && present("settings.result.sendWithCommandEnter") }
            capture(sw, "S-21-search.png", dir)
        }
        var missing: [String] = []
        for row in SettingsRegistry.rows {
            model.query = row.label.string()
            if !(await waitUntil(timeout: 1.5) { present("settings.result.\(row.id)") }) { missing.append(row.id) }
        }
        model.query = ""
        settingsWindow?.makeFirstResponder(nil)
        await settle(200)
        legs["AT-100-1"] = ["pass": opened == "commandComma" && navOrder == expectedNav && typedOK && missing.isEmpty,
                            "opened": opened, "navOrder": navOrder, "typedSearch": typedOK,
                            "rowsSearched": SettingsRegistry.rows.count, "missing": missing]

        // AT-100 (4): Capabilities → Advanced collapsed by default.
        do {
            let ok = await openSection(.capabilities)
            await settle(300)
            let row = present("settings.row.capabilities.advanced")
            let content = present("settings.cap.advanced.content")
            capture(settingsWindow, "S-21-capabilities.png", dir)
            legs["AT-100-4"] = ["pass": ok && row && !content && !model.advancedExpanded, "advancedRow": row,
                                "contentVisible": content]
        }

        // AT-100 (2): change every enabled M1 row once.
        var methods: [String: String] = [:]
        var expected: [String: String] = [:]
        model.advancedExpanded = true  // the Advanced disclosure (its toggle: M1.T25b "Show model info")
        if await waitUntil({ present("settings.control.showModelInfo") }) {
            click("settings.control.showModelInfo", tracking: true)
            _ = await waitUntil { Defaults[.showModelInfo] }
        }
        methods["showModelInfo"] = "click"
        expected["showModelInfo"] = "true"

        // AT-100 (2) + AT-062 (1): continued.
        _ = await openSection(.general)
        await settle(300)
        for (id, want) in [("plainTextComposer", true), ("showContextUsage", true), ("launchAtLogin", true),
                           ("menuBarItem", false)] {
            click("settings.control.\(id)", at: 0.5, tracking: true)
            _ = await waitUntil { values()[id] == "\(want)" }
            methods[id] = "click"
            expected[id] = "\(want)"
        }
        let keepRunningFollows = present("settings.value.keepRunning")
        Defaults[.sendWithCommandEnter] = true  // menu picker: an NSMenu tracking loop cannot be driven in-process
        methods["sendWithCommandEnter"] = "key (menu picker)"
        expected["sendWithCommandEnter"] = "true"
        capture(settingsWindow, "S-21-general-changed.png", dir)

        var limit: [String: Any] = [:]
        _ = await openSection(.personalization)
        await settle(400)
        if let sw = settingsWindow {
            _ = await focusText("settings.control.aboutYou")
            await settle(100)
            await type("I sail.", in: sw)
            let typedAbout = await waitUntil { Defaults[.aboutYou] == "I sail." }
            // Paste 3,005 characters into the focused field (the text view's own insertText, like ⌘V): clamped.
            (sw.firstResponder as? NSTextView)?.insertText(String(repeating: "a", count: 2998), replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle(200)
            let clampedOnSet = Defaults[.aboutYou].count
            Defaults[.aboutYou] = String(repeating: "a", count: 2999)
            await settle(200)
            _ = await focusText("settings.control.aboutYou")
            key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.command, .numericPad, .function], in: sw)  // ⌘↓ end of text
            await type("xyz", in: sw)
            await settle(200)
            let after = Defaults[.aboutYou].count
            limit = ["typedAboutYou": typedAbout, "typed3001stRefused": after == 3000, "countAfterTyping": after,
                     "counterText": CopyText(CopyKey("set.pers.counter"), ["count": "\(after)", "max": "3000"]).string,
                     "storedOverLongValueLength": clampedOnSet]
            capture(sw, "S-21-personalization-full.png", dir)
            Defaults[.aboutYou] = "I sail on weekends."
            methods["aboutYou"] = "typed"
            expected["aboutYou"] = "I sail on weekends."
            _ = await focusText("settings.control.howToRespond")
            await settle(100)
            await type("Be brief.", in: sw)
            _ = await waitUntil { Defaults[.howToRespond] == "Be brief." }
            methods["howToRespond"] = "typed"
            expected["howToRespond"] = "Be brief."
        }
        Defaults[.stylePreset] = "candid"
        methods["stylePreset"] = "key (menu picker)"
        expected["stylePreset"] = "candid"
        for (id, fraction, want) in [("warmth", 0.17, "more"), ("enthusiasm", 0.83, "less"), ("headersAndLists", 0.83, "less"),
                                     ("emoji", 0.17, "more")] {
            _ = await reveal(id, in: .personalization, control: "settings.control.\(id)")
            for _ in 0..<2 where values()[id] != want {  // a click during the reveal scroll can miss: once more
                await settle(400)
                click("settings.control.\(id)", at: fraction, tracking: true)
                _ = await waitUntil(timeout: 1.5) { values()[id] == want }
            }
            methods[id] = "click (segment)"
            expected[id] = want
        }
        await settle(300)
        capture(settingsWindow, "S-21-personalization.png", dir)

        // AT-011 (4): Archived chats, Archive all, Delete all, Auto-archive.
        var archivedLeg: [String: Any] = ["autoArchiveDefaultNever": defaultsBefore["autoArchiveDays"] == "0"]
        do {
            let titles = ["Lisbon trip", "Tax return", "Sourdough", "Garden plan", "Piano practice", "Bike repair"]
            let ids = titles.compactMap { try? chats.create(title: $0).id }
            try? chats.archive([ids[0], ids[1], ids[2]])
            _ = await openSection(.privacy)
            await settle(300)
            capture(settingsWindow, "S-21-privacy.png", dir)
            _ = await reveal("archivedChats", in: .privacy, control: "settings.control.archivedChats")
            await settle(300)
            click("settings.control.archivedChats", tracking: false)
            let pageShown = await waitUntil { present("archived.page") }
            let listed = await waitUntil { [ids[0], ids[1], ids[2]].allSatisfy { present("archived.row.\($0)") } }
            if let pw = window(with: "archived.page") {
                click("archived.search")
                await settle(150)
                await type("lis", in: pw)
            }
            let filtered = await waitUntil {
                present("archived.row.\(ids[0])") && !present("archived.row.\(ids[1])") && !present("archived.row.\(ids[2])")
            }
            capture(window(with: "archived.page"), "S-21-archived-search.png", dir)
            if let pw = window(with: "archived.page") {
                for _ in 0..<3 { key("\u{7f}", code: 51, in: pw); await settle(10) }
            }
            _ = await waitUntil { present("archived.row.\(ids[1])") }
            click("archived.unarchive.\(ids[1])", tracking: false)
            let unarchived = await waitUntil { ((try? chats.archived().map(\.id)) ?? []).contains(ids[1]) == false }
            await press("archived.delete.\(ids[2])") { present("deleteConfirm") }
            capture(window(with: "deleteConfirm"), "S-21-archived-delete-confirm.png", dir)
            if let cw = window(with: "deleteConfirm") { key("\r", code: 36, in: cw) }  // the default action (Return)
            if !(await waitUntil(timeout: 1.5) { (try? chats.chat(ids[2])) == nil }) {
                await press("deleteConfirm") { (try? chats.chat(ids[2])) == nil }
            }
            let deleted = await waitUntil { (try? chats.chat(ids[2])) == nil && !present("archived.row.\(ids[2])") }
            capture(window(with: "archived.page"), "S-21-archived.png", dir)
            await press("archived.done") { !present("archived.page") }

            _ = await reveal("archiveAll", in: .privacy, control: "settings.control.archiveAll")
            await settle(300)
            await press("settings.control.archiveAll") { present("archiveAll.confirm") }
            await press("archiveAll.confirm") { (try? chats.sidebarCount()) == 0 }
            let allArchived = await waitUntil { (try? chats.sidebarCount()) == 0 && (try? chats.totalCount()) == 5 }

            _ = await reveal("deleteAll", in: .privacy, control: "settings.control.deleteAll")
            await settle(300)
            let sheet = await press("settings.control.deleteAll") { present("deleteAll.sheet") }
            capture(window(with: "deleteAll.sheet"), "S-24-delete-all.png", dir)
            click("deleteAll.confirm", tracking: false)  // disabled until DELETE is typed
            await settle(300)
            let refusedUntyped = (try? chats.totalCount()) == 5
            if let dw = window(with: "deleteAll.sheet") {
                click("deleteAll.field")
                await settle(150)
                await type("DELETE", in: dw)
                await settle(200)
            }
            await press("deleteAll.confirm") { (try? chats.totalCount()) == 0 }
            let allDeleted = await waitUntil { (try? chats.totalCount()) == 0 && !present("deleteAll.sheet") }

            Defaults[.autoArchiveDays] = 30
            methods["autoArchiveDays"] = "key (menu picker)"
            expected["autoArchiveDays"] = "30"
            archivedLeg.merge([
                "pass": pageShown && listed && filtered && unarchived && deleted && allArchived && sheet && refusedUntyped
                    && allDeleted && defaultsBefore["autoArchiveDays"] == "0",
                "pageShown": pageShown, "listed": listed, "searchFilters": filtered, "unarchive": unarchived,
                "delete": deleted, "archiveAll": allArchived, "deleteAllSheet": sheet,
                "deleteAllRefusedUntilTyped": refusedUntyped, "deleteAllAfterTypingDELETE": allDeleted,
                "autoArchiveVirtualClock": "AutoArchiveServiceTests.neverByDefaultThenThirtyDaysOnTheNextDailyRun",
            ]) { $1 }
        }
        legs["AT-011-4"] = archivedLeg

        let now = values()
        let changed = expected.filter { now[$0.key] == $0.value }.count
        let allKeys = Set(SettingsKeys.defaults.keys)
        legs["AT-100-2"] = ["pass": changed == expected.count && Set(expected.keys) == allKeys
                                && defaultsBefore == SettingsKeys.defaults && keepRunningFollows,
                            "defaultsBeforeMatchKeys": defaultsBefore == SettingsKeys.defaults,
                            "changed": changed, "expected": expected, "read": now, "methods": methods,
                            "keepRunningRow": keepRunningFollows, "relaunch": "second launch → relaunch.json"]
        legs["AT-062-1"] = limit.merging(["pass": limit["typed3001stRefused"] as? Bool == true
                                              && limit["storedOverLongValueLength"] as? Int == 3000
                                              && limit["typedAboutYou"] as? Bool == true]) { $1 }
        write(expected, dir: dir, name: "written.json")

        // AT-062 (2): what the next turn's prompt carries (the app's PromptSettings, synced from the settings).
        do {
            let settings = sessions.environment.promptSettings
            let composer = PromptComposer()
            func sys(_ mode: PromptMode, _ i: IncognitoPersonalization?) -> String {
                composer.compose(settings.inputs.forTurn(mode: mode, incognito: i)).systemText
            }
            let n = sys(.normal, nil), e = sys(.evil(toneSentence: "Unfiltered. No lectures."), nil)
            let u = sys(.normal, .unpersonalized), p = sys(.normal, .personalized)
            let marker = "I sail on weekends."
            for (name, s) in [("normal", n), ("evil", e), ("incognito-unpersonalized", u), ("incognito-personalized", p)] {
                try? s.write(to: dir.appendingPathComponent("prompt-\(name).txt"), atomically: true, encoding: .utf8)
            }
            legs["AT-062-2"] = ["pass": n.contains(marker) && e.contains(marker) && !u.contains(marker) && p.contains(marker)
                                    && n.contains("Be brief."),
                                "normal": n.contains(marker), "evil": e.contains(marker),
                                "incognitoUnpersonalized": u.contains(marker), "incognitoPersonalized": p.contains(marker)]
        }

        await closeSettings()

        // AT-100 (3): the sidebar footer menu.
        do {
            var items: [String: Bool] = [:]
            func openMenu() async -> Bool {
                BackgroundRun.makeKeyAndOrderFront(main)
                await settle(200)
                click("sidebar.settings", tracking: false)
                return await waitUntil { present("footer.menu") }
            }
            let menuOK = await openMenu()
            let hasAll = ["settings", "help", "report", "updates"].allSatisfy { present("footer.\($0)") }
            capture(window(with: "footer.menu"), "S-05-footer-menu.png", dir)
            click("footer.settings", tracking: false)
            items["settings"] = await waitUntil { settingsWindow != nil }
            await closeSettings()
            _ = await openMenu()
            click("footer.help", tracking: false)
            items["help"] = await waitUntil { present("help.guide") }
            click("help.close", tracking: false)
            _ = await waitUntil { !present("help.guide") }
            _ = await openMenu()
            click("footer.report", tracking: false)
            items["report"] = await waitUntil { main.attachedSheet != nil && !present("help.guide") }
            if let sheet = main.attachedSheet {
                key("\u{1b}", code: 53, in: sheet)
                if !(await waitUntil { main.attachedSheet == nil }) { main.endSheet(sheet) }
            }
            _ = await openMenu()
            click("footer.updates", tracking: false)
            items["updates"] = await waitUntil { settingsWindow != nil && model.selection == .updates
                && present("settings.row.updates.later") }
            capture(settingsWindow, "S-21-updates.png", dir)
            await closeSettings()
            legs["AT-100-3"] = ["pass": menuOK && hasAll && items.values.allSatisfy { $0 } && items.count == 4,
                                "menuShown": menuOK, "allFourItems": hasAll, "opened": items]
        }

        // AT-012 (2): ⌘K → "send with" → Return opens Settings at that row.
        do {
            var pass = false
            var info: [String: Any] = [:]
            if let palette = PaletteController.lastAttached {
                BackgroundRun.makeKeyAndOrderFront(main)
                await settle(200)
                let how = await PaletteProbe.open(palette)
                _ = await PaletteProbe.search("send with", palette)
                await settle(200)
                let idx = palette.items.firstIndex { $0.id == "setting.sendWithCommandEnter" }
                if let idx {
                    for _ in 0..<idx { PaletteProbe.down(); await settle(60) }
                    PaletteProbe.returnKey()
                }
                let atRow = await waitUntil(timeout: 4) {
                    settingsWindow != nil && model.selection == .general
                        && model.highlightedRow == "sendWithCommandEnter" && present("settings.row.sendWithCommandEnter")
                }
                capture(settingsWindow, "S-21-from-palette.png", dir)
                pass = idx != nil && atRow
                info = ["opened": how, "rowIndex": idx ?? -1, "settingsAtRow": atRow,
                        "highlighted": model.highlightedRow ?? ""]
                await closeSettings()
            }
            legs["AT-012-2"] = info.merging(["pass": pass]) { $1 }
        }

        // AT-002 (4)–(5) / AT-009 (1) through the UI: the composer and the indicator follow the toggled settings.
        legs["UI-toggles"] = await toggledSettingsTakeEffect(state, sessions: sessions, dir: dir, name: "ui")

        let pass = legs.values.allSatisfy { $0["pass"] as? Bool == true }
        return ["mode": "full", "pass": pass, "legs": legs]
    }

    /// The composer reads Send with / Plain-text composer; a turn shows the context-usage indicator.
    static func toggledSettingsTakeEffect(_ state: WindowState, sessions: ChatSessions, dir: URL,
                                          name: String) async -> [String: Any] {
        BackgroundRun.makeKeyAndOrderFront(main)
        await settle(200)
        let composer = sessions.composer
        let sendWith = composer.sendWithCommandEnter
        let plain = composer.plainTextComposer
        let turn = await ContextProbe.turn("Hello there, a short question.", sessions: sessions, state: state)
        let indicator = await waitUntil(timeout: 4) { ContextProbe.count("contextUsage") > 0 }
        capture(main, "context-usage-\(name).png", dir)
        return ["pass": sendWith && plain && turn && indicator, "composerSendWithCommandEnter": sendWith,
                "composerPlainText": plain, "turn": turn, "contextUsageShown": indicator]
    }

    // MARK: Relaunch / launch-argument runs

    static func relaunch(_ dir: URL) async -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("written.json")),
              let expected = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ["mode": "relaunch", "pass": false, "error": "unreadable written.json"]
        }
        let now = values()
        let mismatched = expected.filter { now[$0.key] != $0.value }.map(\.key).sorted()
        return ["mode": "relaunch", "pass": mismatched.isEmpty && !expected.isEmpty, "read": now,
                "mismatched": mismatched]
    }

    static func launchArguments(_ state: WindowState, sessions: ChatSessions, dir: URL) async -> [String: Any] {
        guard await setUp() else { return ["mode": "launchargs", "pass": false, "error": "no AntiChat window"] }
        let v = values()
        let stored = ["sendWithCommandEnter", "plainTextComposer", "showContextUsage"].map {
            UserDefaults.antichat.persistentDomain(forName: LaunchOptions.current.defaultsSuite ?? "")?[$0] != nil
        }
        var leg = await toggledSettingsTakeEffect(state, sessions: sessions, dir: dir, name: "launchargs")
        let read = v["sendWithCommandEnter"] == "true" && v["plainTextComposer"] == "true" && v["showContextUsage"] == "true"
        leg["defaultsRead"] = read
        leg["writtenToDisk"] = stored
        leg["pass"] = (leg["pass"] as? Bool == true) && read && !stored.contains(true)
        return ["mode": "launchargs", "pass": leg["pass"] as? Bool == true, "legs": ["launch-arguments": leg]]
    }
}
#endif
