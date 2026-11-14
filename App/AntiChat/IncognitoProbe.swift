// M1.T20 in-process incognito probe (AT-090 journey 8, AT-NFR-PR3). XCUITest is blocked on this Mac (Q-015), so —
// like TurnProbe / PaletteProbe — the app drives its own window: ⇧⌘N (a key event through the menu), the toolbar
// IncognitoButton (a real click on its probe anchor), ⌘K → "New incognito chat" (PaletteController.activate), the
// composer (ComposerModel.send with a 12k paste card), regenerate (ConversationModel.regenerate), ⌘W
// (`NSWindow.performClose`, answered by the window guard) and ⌘Q (`NSApp.terminate`, held by the app delegate).
// Disk-diff handshake (tools/ci/disk-diff.py): the probe does its on-disk setup (a normal chat with a message, for
// the disabled-button leg), writes `<dir>/ready`, waits for `<dir>/go` (the runner snapshots the data folders in
// between), runs the incognito journey, writes `<dir>/probe.json` and quits through the incognito confirmation.
// The phrases it types and pastes come from `<dir>/phrases.txt` (fixtures/prompts/copy-check/incognito-phrases.txt).
// DEBUG only (`-IncognitoProbe <dir>`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum IncognitoProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("IncognitoProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
        }
    }

    static func settle(_ ms: Int) async { await PaletteProbe.settle(ms) }
    static func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        await PaletteProbe.waitUntil(timeout: timeout, cond) != nil
    }

    static func phrases(_ dir: URL) -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("phrases.txt"), encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.count >= 6 ? lines : (1...6).map { "incognito probe phrase \($0) quillfeather" }
    }

    /// What the window shows for an incognito chat right now (leg 1).
    static func incognitoUI(_ state: WindowState, _ sessions: ChatSessions) -> [String: Bool] {
        [
            "route": state.isIncognito,
            "frame": PaletteProbe.present("incognitoFrame"),
            "badge": PaletteProbe.present("incognitoBadge"),
            "dashedComposer": sessions.composer.isIncognito,
            "headline": PaletteProbe.present("incognitoHeadline"),
            "sub": PaletteProbe.present("incognitoSub"),
            "personalizationChoice": PaletteProbe.present("incognitoPersonalization"),
            "buttonOn": PaletteProbe.present("incognitoButton"),
            "restorableOff": !(PaletteProbe.window?.isRestorable ?? true),
        ]
    }

    static func waitIdle(_ state: WindowState, _ sessions: ChatSessions) async -> Bool {
        await settle(100)
        return await waitUntil(60) {
            guard let id = state.currentChatID else { return false }
            let m = sessions.model(for: id)
            return !m.isGenerating && m.messages.last?.role == .assistant && m.messages.last?.status != .pending
        }
    }

    static func send(_ text: String, paste: String? = nil, _ state: WindowState, _ sessions: ChatSessions) async -> Bool {
        sessions.composer.text = text
        if let paste { _ = sessions.composer.handlePaste(paste) }
        await settle(60)
        guard sessions.composer.send() else { return false }
        return await waitIdle(state, sessions)
    }

    static func layerText(_ r: ChatRequest?) -> String {
        (r?.messages ?? []).compactMap { if case .layer(let l) = $0 { return l.content } else { return nil } }
            .joined(separator: "\n")
    }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await settle(1500)
        // The probe's own window and palette (not "the first window" / the last palette attached: ⇧⌘N below opens
        // a second main window, M1.T24).
        guard let window = state.window ?? NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }),
              let palette = state.palette ?? PaletteController.lastAttached else {
            write(["error": "no AntiChat window or palette"], dir: dir)
            NSApp.terminate(nil)
            return
        }
        PaletteProbe.window = window
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        BackgroundRun.makeKeyAndOrderFront(window)
        BackgroundRun.activate()
        await settle(600)
        let words = phrases(dir)
        var result: [String: Any] = ["phrases": words.count]
        let env = sessions.environment

        // Setup on disk (before the snapshot): a normal chat with a message → the IncognitoButton is disabled there.
        var disabledLeg: [String: Any] = [:]
        do {
            let chat = try state.service.create(title: "Probe normal chat")
            try state.service.appendUserMessage(chat.id, text: "hello")
            state.open(.chat(chat.id))
            await settle(400)
            disabledLeg = ["inNonEmptyChat": !state.canToggleIncognito, "buttonPresent": PaletteProbe.present("incognitoButton")]
            state.newChat()
            await settle(300)
            disabledLeg["onNewChat"] = state.canToggleIncognito
        } catch {
            disabledLeg["error"] = "\(error)"
        }
        disabledLeg["pass"] = (disabledLeg["inNonEmptyChat"] as? Bool ?? false) && (disabledLeg["onNewChat"] as? Bool ?? false)
        result["AT-090-1-disabled"] = disabledLeg
        sessions.warmup()
        _ = await waitUntil(20) { sessions.readiness.acceptsRequests }
        let sidebarBefore = (try? state.service.sidebarCount()) ?? -1
        // The app's Personalization (memory only until M1.T22): the Unpersonalized prompt must not carry it.
        let aboutYou = words[5]
        env.promptSettings.update { $0.personalization.aboutYou = aboutYou }

        // Handshake: the runner snapshots the data folders now.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("ready").path, contents: Data())
        _ = await waitUntil(300) { FileManager.default.fileExists(atPath: dir.appendingPathComponent("go").path) }

        // Leg 1: the three entry points.
        var entry: [String: Any] = [:]
        result["diag"] = [
            "mainWindows": NSApp.windows.filter { $0.isVisible && $0.title == "AntiChat" }.count,
            "paletteOfProbeState": state.palette === palette,
            "openIncognitoSessions": AppLog.openIncognitoSessions,
        ] as [String: Any]
        // ⇧⌘N = File › New Incognito Chat: a new main window that opens on a fresh incognito chat (M1.T24,
        // WindowRestoration). A background run's app is never active, so no window is key and NSApp.sendEvent has
        // nothing to route a key equivalent to: the same key event goes to the main menu (the item's real shortcut
        // path, as AppKit does for a key window). `charactersIgnoringModifiers` keeps the Shift ("N"), as a real
        // keyboard event does; "n" matches ⌘N (New Chat), which opens a regular window when no window is focused.
        let before = Set(IncognitoQuitGuard.liveStates.map(ObjectIdentifier.init))
        func newIncognitoWindow() -> WindowState? {
            IncognitoQuitGuard.liveStates.first { !before.contains(ObjectIdentifier($0)) && $0.isIncognito && $0.window != nil }
        }
        PaletteProbe.key("N", code: 45, flags: [.command, .shift])
        if await waitUntil(3, { newIncognitoWindow() != nil }) == false,
           let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: "N", charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 45) {
            entry["shiftCmdNViaMainMenu"] = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
        }
        if newIncognitoWindow() == nil, entry["shiftCmdNViaMainMenu"] as? Bool != true {
            // AppKit matches no synthetic ⇧⌘N to a menu item in an app that is not active: run the item that carries
            // the ⇧⌘N key equivalent (the menu's own binding, ShortcutBindings) the way its key would.
            func find(_ m: NSMenu) -> (NSMenu, Int)? {
                for (i, it) in m.items.enumerated() {
                    if it.keyEquivalent.lowercased() == "n", it.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
                        return (m, i)
                    }
                    if let sub = it.submenu, let r = find(sub) { return r }
                }
                return nil
            }
            if let menu = NSApp.mainMenu, let (m, i) = find(menu) {
                entry["shiftCmdNItem"] = m.items[i].title
                m.performActionForItem(at: i)
            }
        }
        _ = await waitUntil(10) { newIncognitoWindow() != nil }
        await settle(500)
        var ui: [String: Bool]
        if let other = newIncognitoWindow(), let w = other.window {
            PaletteProbe.window = w
            ui = incognitoUI(other, sessions)
            ui["dashedComposer"] = nil  // the new window has its own ChatSessions (not the probe window's composer)
            ui["newWindow"] = w !== window
            w.performClose(nil)  // an empty incognito chat closes without asking
            _ = await waitUntil(5) { other.incognito == nil || !w.isVisible }
            ui["closedClean"] = other.incognito == nil && AppLog.openIncognitoSessions == 0
            PaletteProbe.window = window
            BackgroundRun.makeKeyAndOrderFront(window)
        } else {
            ui = incognitoUI(state, sessions)
            ui["newWindow"] = false
        }
        await settle(300)
        entry["shiftCmdN"] = ui
        let shiftCmdN = ui.values.allSatisfy { $0 }
        // The toolbar IncognitoButton in the probe's window: off → on (a fresh incognito chat), on → off (back).
        _ = SettingsProbe.click("incognitoButton", in: window)
        _ = await waitUntil(3) { state.isIncognito }
        await settle(400)
        ui = incognitoUI(state, sessions)
        entry["toolbarButton"] = ui
        let button = ui.values.allSatisfy { $0 }
        // S-07 captures from the probe's own window (laid out since launch; a just-opened window can still be blank).
        capture("S-07-light.png", dir)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle(500)
        capture("S-07-dark.png", dir)
        NSApp.appearance = nil
        _ = SettingsProbe.click("incognitoButton", in: window)  // on → off (empty incognito chat: back to a new chat)
        _ = await waitUntil(3) { !state.isIncognito }
        entry["buttonOffLeaves"] = !state.isIncognito && state.incognito == nil
        await settle(300)
        state.newChat()
        await settle(300)
        palette.present()
        await settle(200)
        palette.activate("action.newIncognitoChat")
        _ = await waitUntil(3) { state.isIncognito }
        await settle(400)
        ui = incognitoUI(state, sessions)
        entry["paletteAction"] = ui
        let viaPalette = ui.values.allSatisfy { $0 }
        entry["pass"] = shiftCmdN && button && viaPalette && (entry["buttonOffLeaves"] as? Bool ?? false)
        result["AT-090-1"] = entry
        // M8.T16: when no input path entered incognito (a background run routes no key equivalent / control click),
        // enter it through the same WindowState action so the privacy legs (2–4, disk diff, M8 checks) still run;
        // leg 1 stays failed with the reason.
        if !state.isIncognito {
            state.newChat()
            await settle(200)
            state.newIncognitoChat()
            _ = await waitUntil(3) { state.isIncognito }
            await settle(400)
            entry["fallbackEnteredViaWindowState"] = state.isIncognito
            result["AT-090-1"] = entry
        }

        // Leg 3 (+ leg 2's journey): Unpersonalized, 3 turns incl. a 12k paste card and a regenerate.
        var journey: [String: Any] = [:]
        let choiceShown = PaletteProbe.present("incognitoPersonalization")
        state.incognitoPersonalization = .unpersonalized
        let session = state.incognito
        let temp = session?.tempDirectory
        journey["tempDir"] = temp?.path ?? ""
        journey["tempDirExists"] = temp.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let card = words[1] + " " + String(String(repeating: "lorem ipsum dolor sit amet ", count: 460).prefix(12_000))
        let t1 = await send(words[0], paste: card, state, sessions)
        let afterFirst = session?.engine.lastRequest
        let t2 = await send(words[2], state, sessions)
        var regen = false
        if let id = state.currentChatID, let last = sessions.model(for: id).messages.last(where: { $0.role == .assistant }) {
            sessions.model(for: id).regenerate(last.id)
            regen = await waitIdle(state, sessions)
        }
        let t3 = await send(words[3], state, sessions)
        let chatID = state.currentChatID ?? ""
        let m = sessions.model(for: chatID)
        let req = session?.engine.lastRequest
        journey["turns"] = [t1, t2, t3]
        journey["regenerated"] = regen
        journey["messages"] = m.messages.count
        journey["requests"] = session?.engine.requestCount ?? 0
        journey["allFlaggedIncognito"] = req?.incognito == true && afterFirst?.incognito == true
        journey["routedToMemory"] = env.stores.isEphemeral(chatID)
        journey["storeInMemory"] = session?.store.isInMemory ?? false
        journey["pasteCardSent"] = (afterFirst?.flattenedMessages.last { $0.role == .user }?.content.contains(words[1])) ?? false
        journey["noSidebarRow"] = ((try? state.service.sidebarCount()) ?? -2) == sidebarBefore
            && !state.sidebar.contains { $0.id == chatID }
        journey["notOnDisk"] = ((try? state.service.chat(chatID)) ?? nil) == nil
            && words.prefix(4).allSatisfy { ((try? state.service.search($0)) ?? []).isEmpty }
        journey["logRedaction"] = AppLog.isRedacting
        journey["titleNotGenerated"] = sessions.titleLatency[chatID] == nil
        journey["choiceLockedAfterFirst"] = session?.setPersonalization(.personalized) == false
        journey["pass"] = t1 && t2 && t3 && regen && (journey["allFlaggedIncognito"] as? Bool ?? false)
            && (journey["routedToMemory"] as? Bool ?? false) && (journey["noSidebarRow"] as? Bool ?? false)
            && (journey["notOnDisk"] as? Bool ?? false) && (journey["pasteCardSent"] as? Bool ?? false)
            && (journey["titleNotGenerated"] as? Bool ?? false)
        result["AT-090-2-journey"] = journey
        let unpersonalizedLayers = layerText(afterFirst)
        result["AT-090-3"] = [
            "choiceShownBeforeFirstMessage": choiceShown,
            "defaultPersonalized": (entry["paletteAction"] != nil),
            "unpersonalizedOmitsInstructions": !unpersonalizedLayers.contains(aboutYou),
            "requestLayers": afterFirst?.messages.filter { if case .layer = $0 { return true } else { return false } }.count ?? 0,
            "pass": choiceShown && !unpersonalizedLayers.contains(aboutYou) && afterFirst != nil,
        ] as [String: Any]

        // Leg 4a: ⌘W with content → confirmation; Cancel keeps the chat; ⌘N → confirmation; Close discards it.
        var close: [String: Any] = [:]
        window.performClose(nil)
        await settle(500)
        close["closeAsks"] = state.pendingIncognitoLeave == .closeWindow && window.isVisible
        capture("S-07-confirm.png", dir)
        state.cancelIncognitoLeave()
        await settle(300)
        close["cancelKeeps"] = state.isIncognito && state.hasIncognitoContent && window.isVisible
        state.newChat()
        await settle(300)
        close["newChatAsks"] = state.pendingIncognitoLeave == .newChat && state.isIncognito
        state.confirmIncognitoLeave()
        await settle(400)
        close["confirmDiscards"] = !state.isIncognito && state.incognito == nil && (session?.isClosed ?? false)
        close["tempDirGone"] = temp.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        close["routingReleased"] = !env.stores.isEphemeral(chatID)
        close["storeEmptied"] = ((try? session?.store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") }) ?? nil) == 0
        close["modelDropped"] = !sessions.activeChats.contains(chatID)
        close["logRedactionEnded"] = AppLog.openIncognitoSessions == 0
        close["pass"] = ["closeAsks", "cancelKeeps", "newChatAsks", "confirmDiscards", "tempDirGone", "routingReleased",
                         "storeEmptied", "logRedactionEnded"].allSatisfy { close[$0] as? Bool ?? false }
        result["AT-090-4-close"] = close

        // Leg 3b: Personalized includes the instruction layer (read-only).
        state.newIncognitoChat()
        await settle(400)
        let defaultChoice = state.incognitoPersonalization == .personalized
        let tp = await send(words[4], state, sessions)
        let personalizedReq = state.incognito?.engine.lastRequest
        var leg3 = result["AT-090-3"] as? [String: Any] ?? [:]
        leg3["defaultPersonalized"] = defaultChoice
        leg3["personalizedIncludesInstructions"] = layerText(personalizedReq).contains(aboutYou)
        leg3["settingsUnchanged"] = env.promptSettings.inputs.personalization.aboutYou == aboutYou
        leg3["pass"] = (leg3["pass"] as? Bool ?? false) && tp && defaultChoice
            && (leg3["personalizedIncludesInstructions"] as? Bool ?? false)
        result["AT-090-3"] = leg3

        // M8.T16 PR3 re-run with M8 present: a memory-style request in incognito writes no memory (rows or
        // suggestions), and its finished replies notify (the app runs in the background) without naming anything.
        let rem = await send("Remember that my favourite colour is teal.", state, sessions)
        await settle(1500)
        func count(_ table: String) -> Int {
            (try? env.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }) ?? -1
        }
        let answers = ((NotificationService.shared.client as? SpyUserNotificationClient)?.requests ?? []).filter { $0.category == .answer }
        let m8: [String: Any] = [
            "sent": rem, "memoryItems": count("memory_item"), "memorySuggestions": count("memory_suggestion"),
            "answerNotifications": answers.count,
            "bodies": Array(Set(answers.map(\.body))), "titles": Array(Set(answers.map(\.title))),
        ]
        result["AT-NFR-PR3-m8"] = m8.merging(["pass": rem && count("memory_item") == 0 && count("memory_suggestion") == 0
            && answers.allSatisfy { $0.body == "Incognito chat: reply ready" && $0.title == "Incognito" && $0.userInfo["chatID"] == nil }]) { a, _ in a }

        // Leg 4b: quit with content → confirmation; confirm quits (the runner checks the temp dir afterwards).
        let quitTemp = state.incognito?.tempDirectory
        // ⌘Q arrives from the run loop, never from inside a main-queue job: AppKit's `.terminateLater` wait must not
        // block this task (the confirmation is answered below).
        RunLoop.main.perform { NSApp.terminate(nil) }
        await settle(800)
        let quitAsks = state.pendingIncognitoLeave == .quit
        result["AT-090-4-quit"] = ["quitAsks": quitAsks, "tempDir": quitTemp?.path ?? "", "pass": quitAsks]
        let legs = result.filter { $0.key.hasPrefix("AT-") }.compactMap { $0.value as? [String: Any] }
        result["pass"] = legs.allSatisfy { $0["pass"] as? Bool ?? false }
        write(result, dir: dir)
        FileHandle.standardError.write(Data("IncognitoProbe: done\n".utf8))
        if quitAsks {
            state.confirmIncognitoLeave()  // → NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            state.discardIncognito()
            NSApp.terminate(nil)
        }
    }

    /// The probe window drawn into a PNG. `screencapture -l` gives a blank image in a background run (the window is
    /// ordered in at alpha 0, BackgroundRun.conceal); `cacheDisplay` of the frame view (toolbar included) is unaffected.
    static func capture(_ name: String, _ dir: URL) {
        guard BackgroundRun.isOn else { return PaletteProbe.capture(name, dir) }
        guard let view = PaletteProbe.window?.contentView?.superview ?? PaletteProbe.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }
}
#endif
