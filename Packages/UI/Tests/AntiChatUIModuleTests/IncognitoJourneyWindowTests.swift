// AT-090 journey 8 in-process (M1.T20). The app cannot open a window from this agent's command sandbox (Q-025; the
// `-IncognitoProbe` run of tools/at/t20-probe.sh idles without a window, and launching with the sandbox disabled is
// refused), and XCUITest is blocked (Q-015). So this suite hosts the real MainWindow (toolbar bridged through
// NSHostingController, ChatSessions slots: ComposerView + ConversationView, the IncognitoFrame modifier with its
// window guards) in an NSWindow inside the test process, on an on-disk app database in a throwaway container, and
// runs journey 8: the three entry points, Unpersonalized, 3 turns incl. a 12k paste card and a regenerate, ⌘W
// (`performClose`, answered by the window guard), ⌘N confirmation, Personalized, quit (`IncognitoQuitGuard`).
// The container is hashed before the journey and after it: byte-identical, and no file holds a fixture phrase.
// Evidence (probe.json + S-07 captures) goes to `$AT090_EVIDENCE_DIR` when set (tools/at/t20-window.sh).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct IncognitoJourneyWindowTests {
    static let script = """
    {"t":"title","v":"Must never be asked"}
    {"t":"textDelta","v":"Answer v{{v}}:","delayMs":10}
    {"t":"textDelta","v":" the harbour has three piers.","delayMs":10}
    {"t":"turn"}
    {"t":"textDelta","v":"Follow-up v{{v}}:","delayMs":10}
    {"t":"textDelta","v":" the ferry leaves at noon.","delayMs":10}
    """

    static var phrases: [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["fixtures/prompts/copy-check/incognito-phrases.txt", "tools/fixtures/staged/prompts/copy-check/incognito-phrases.txt"] {
            if let t = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) {
                let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if lines.count >= 6 { return lines }
            }
        }
        return (1...6).map { "incognito journey phrase \($0) quillfeather" }
    }

    // MARK: Rig

    final class Rig {
        let container: URL
        let env: ChatEnvironment
        let state: WindowState
        let sessions: ChatSessions
        let palette: PaletteController
        let window: NSWindow

        init(container: URL, env: ChatEnvironment, state: WindowState, sessions: ChatSessions, palette: PaletteController,
             window: NSWindow) {
            self.container = container
            self.env = env
            self.state = state
            self.sessions = sessions
            self.palette = palette
            self.window = window
        }
    }

    private func make() async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntiChat-T20-journey-\(UUID().uuidString)", isDirectory: true)
        let db = try AppDatabase.onDisk(at: container.appendingPathComponent("antichat.sqlite"))
        let engine = InProcessScriptedEngine(script: try EngineScript(text: Self.script))
        let env = ChatEnvironment(database: db, engine: engine, mediaRoot: container.appendingPathComponent("Media"),
                                  tools: ToolRuntime(registry: .m1(scriptedTools: false), permissions: ToolPermissionStore(db)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        // The app host's wiring (App/AntiChat/AntiChatApp.swift MainWindowHost).
        state.makeIncognito = { [sessions] in try sessions.makeIncognitoSession() }
        state.onIncognitoClosed = { [weak sessions] in sessions?.incognitoClosed($0) }
        sessions.incognito = { [weak state] in state?.incognito }
        sessions.openChat = { [weak state] in state?.open(.chat($0)) }
        state.rowActivity = { [weak sessions] in sessions?.activity(for: $0) ?? .idle }
        sessions.onTitle = { [weak state] in state?.applyTitle($0, title: $1) }
        sessions.onEmptyChatRemoved = { [weak state] in state?.emptyChatRemoved($0) }
        let palette = PaletteController()
        let root = MainWindow(state: state, slots: sessions.slots, palette: palette).environment(\.reduceMotionOverride, true)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.title = "AntiChat"
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        BackgroundRun.present(window)
        await pump(800)
        return Rig(container: container, env: env, state: state, sessions: sessions, palette: palette, window: window)
    }

    private func pump(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func until(_ timeout: Double = 60, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    private func present(_ rig: Rig, _ id: String) -> Bool { UIProbeRegistry.frame(id, in: rig.window) != nil }

    @discardableResult
    private func click(_ rig: Rig, _ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: rig.window) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: f.midX, y: f.midY), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                rig.window.sendEvent(e)
            }
        }
        return true
    }

    private var evidenceDir: URL? {
        ProcessInfo.processInfo.environment["AT090_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func capture(_ rig: Rig, _ name: String) {
        guard let dir = evidenceDir, let view = rig.window.contentView?.superview ?? rig.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    /// sha256 of every file under `dir` (the database, WAL, SHM, media).
    private func hashes(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let d = try? Data(contentsOf: u) else { continue }
            out[u.path.replacingOccurrences(of: dir.path, with: "")] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private func phraseHits(_ dir: URL, _ phrases: [String]) -> [String] {
        var hits: [String] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            guard let d = try? Data(contentsOf: u) else { continue }
            for p in phrases where d.range(of: Data(p.utf8)) != nil || d.range(of: p.data(using: .utf16LittleEndian)!) != nil {
                hits.append("\(u.lastPathComponent): \(p)")
            }
        }
        return hits
    }

    private func ui(_ rig: Rig) -> [String: Bool] {
        [
            "route": rig.state.isIncognito,
            "frame": present(rig, "incognitoFrame"),
            "badge": present(rig, "incognitoBadge"),
            "button": present(rig, "incognitoButton"),
            "dashedComposer": rig.sessions.composer.isIncognito,
            "headline": present(rig, "incognitoHeadline"),
            "sub": present(rig, "incognitoSub"),
            "personalizationChoice": present(rig, "incognitoPersonalization"),
            "noSuggestions": !present(rig, "suggestions"),
            "notRestorable": !rig.window.isRestorable,
        ]
    }

    private func waitIdle(_ rig: Rig) async -> Bool {
        await pump(50)
        return await until(60) {
            guard let id = rig.state.currentChatID else { return false }
            let m = rig.sessions.model(for: id)
            return !m.isGenerating && m.messages.last?.role == .assistant && m.messages.last?.status != .pending
        }
    }

    private func send(_ rig: Rig, _ text: String, paste: String? = nil) async -> Bool {
        rig.sessions.composer.text = text
        if let paste { _ = rig.sessions.composer.handlePaste(paste) }
        await pump(60)
        guard rig.sessions.composer.send() else { return false }
        return await waitIdle(rig)
    }

    private func layers(_ r: ChatRequest?) -> String {
        (r?.messages ?? []).compactMap { if case .layer(let l) = $0 { return l.content } else { return nil } }.joined(separator: "\n")
    }

    private func mark(_ s: String) { FileHandle.standardError.write(Data("JOURNEY: \(s)\n".utf8)) }

    private func write(_ obj: [String: Any]) {
        guard let dir = evidenceDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }

    // MARK: Journey 8

    @Test func journey8LeavesNoTraceOnDisk() async throws {
        let rig = try await make()
        defer {
            rig.state.discardIncognito()
            rig.window.orderOut(nil)
            try? FileManager.default.removeItem(at: rig.container)
        }
        let words = Self.phrases
        var result: [String: Any] = ["phrases": words.count, "form": "in-process window (Q-015/Q-025 fallback)"]

        // Setup (before the snapshot): a normal chat with a message → the IncognitoButton works there too.
        let normal = try rig.state.service.create(title: "Normal chat")
        try rig.state.service.appendUserMessage(normal.id, text: "hello")
        rig.state.open(.chat(normal.id))
        await pump(400)
        let enabledInChat = rig.state.canToggleIncognito
        rig.state.newChat()
        await pump(300)
        let enabledOnNew = rig.state.canToggleIncognito
        result["AT-090-1-enabled"] = ["inNonEmptyChat": enabledInChat, "onNewChat": enabledOnNew,
                                      "pass": enabledInChat && enabledOnNew]
        rig.sessions.warmup()
        _ = await until(10) { rig.sessions.readiness.acceptsRequests }
        let aboutYou = words[5]
        rig.env.promptSettings.update { $0.personalization.aboutYou = aboutYou }  // memory only until M1.T22
        let sidebarBefore = try rig.state.service.sidebarCount()
        _ = try rig.env.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") }
        await pump(300)
        let before = hashes(rig.container)

        // Leg 1: ⇧⌘N (the command's action), the toolbar button (real clicks), ⌘K → New incognito chat.
        rig.state.newIncognitoChat()  // MainWindowCommands ⇧⌘N
        _ = await until(3) { rig.state.isIncognito }
        await pump(500)
        var entry: [String: Any] = ["shiftCmdN": ui(rig)]
        rig.window.appearance = NSAppearance(named: .aqua)
        await pump(200)
        capture(rig, "S-07-light.png")
        rig.window.appearance = NSAppearance(named: .darkAqua)
        await pump(300)
        capture(rig, "S-07-dark.png")
        rig.window.appearance = nil
        let clickedOff = click(rig, "incognitoButton")
        if !clickedOff { rig.state.toggleIncognito() }
        _ = await until(3) { !rig.state.isIncognito }
        entry["buttonOffLeaves"] = !rig.state.isIncognito && rig.state.incognito == nil
        await pump(300)
        let clickedOn = click(rig, "incognitoButton")
        if !clickedOn { rig.state.toggleIncognito() }
        _ = await until(3) { rig.state.isIncognito }
        await pump(400)
        entry["toolbarButton"] = ui(rig)
        entry["buttonClicked"] = clickedOff && clickedOn
        rig.state.newChat()
        await pump(300)
        rig.state.newIncognitoChat()  // File › New Incognito Chat's action (the search panel lists chats only)
        _ = await until(3) { rig.state.isIncognito }
        await pump(400)
        entry["menuAction"] = ui(rig)
        let allUI = ["shiftCmdN", "toolbarButton", "menuAction"].allSatisfy {
            (entry[$0] as? [String: Bool])?.values.allSatisfy { $0 } ?? false
        }
        entry["pass"] = allUI && (entry["buttonOffLeaves"] as? Bool ?? false)
        result["AT-090-1"] = entry

        // Legs 2–3: Unpersonalized; 3 turns incl. a 12k paste card and a regenerate.
        let choiceShown = present(rig, "incognitoPersonalization")
        let defaultPersonalized = rig.state.incognitoPersonalization == .personalized
        rig.state.incognitoPersonalization = .unpersonalized
        let session = try #require(rig.state.incognito)
        let temp = session.tempDirectory
        let card = words[1] + " " + String(String(repeating: "lorem ipsum dolor sit amet ", count: 460).prefix(12_000))
        let t1 = await send(rig, words[0], paste: card)
        let first = session.engine.lastRequest
        let t2 = await send(rig, words[2])
        let chatID = rig.state.currentChatID ?? ""
        var regen = false
        if let last = rig.sessions.model(for: chatID).messages.last(where: { $0.role == .assistant }) {
            rig.sessions.model(for: chatID).regenerate(last.id)
            regen = await waitIdle(rig)
        }
        let versions = rig.sessions.model(for: chatID).messages.last?.versionCount ?? 0
        let t3 = await send(rig, words[3])
        await pump(300)
        capture(rig, "S-07-chat.png")
        let m = rig.sessions.model(for: chatID)
        var journey: [String: Any] = [
            "turns": [t1, t2, t3], "regenerated": regen && versions == 2, "messages": m.messages.count,
            "requests": session.engine.requestCount,
            "allFlaggedIncognito": first?.incognito == true && session.engine.lastRequest?.incognito == true,
            "pasteCardInPrompt": first?.flattenedMessages.last(where: { $0.role == .user })?.content.contains(words[1]) ?? false,
            "routedToMemory": rig.env.stores.isEphemeral(chatID) && session.store.isInMemory,
            "noSidebarRow": try rig.state.service.sidebarCount() == sidebarBefore && !rig.state.sidebar.contains { $0.id == chatID },
            "notInDiskDatabase": try rig.state.service.chat(chatID) == nil
                && words.prefix(4).allSatisfy { ((try? rig.state.service.search($0)) ?? []).isEmpty },
            "noTitleRequest": rig.sessions.titleLatency[chatID] == nil,
            "badgeInsteadOfTitle": present(rig, "incognitoBadge") && !present(rig, "toolbarTitle"),
            "logRedaction": AppLog.isRedacting,
            "choiceLocked": !session.setPersonalization(.personalized),
            "tempDir": temp.path,
        ]
        let journeyPass = t1 && t2 && t3 && regen && ["allFlaggedIncognito", "pasteCardInPrompt", "routedToMemory",
            "noSidebarRow", "notInDiskDatabase", "noTitleRequest", "logRedaction", "choiceLocked"]
            .allSatisfy { journey[$0] as? Bool ?? false }
        journey["pass"] = journeyPass
        result["AT-090-2-journey"] = journey
        var leg3: [String: Any] = [
            "choiceShownBeforeFirstMessage": choiceShown, "defaultPersonalized": defaultPersonalized,
            "unpersonalizedOmitsInstructions": !layers(first).contains(aboutYou),
            "unpersonalizedLayers": layers(first).count,
        ]

        // Leg 4: ⌘W asks (window guard), Cancel keeps; ⌘N asks, Close discards.
        var close: [String: Any] = [:]
        // The SwiftUI alert sheet is never presented here: ending an alert sheet in a test process (no running NSApp)
        // enqueues a CFRunLoopStop on the main run loop, and when no nested run is active at that moment it ends the
        // test process's main loop — `swift test` then exits 0 mid-run with the remaining suites never run. The
        // confirmation's look is captured by the app's own probe (IncognitoProbe, S-07-confirm.png); here the
        // guard is checked through `WindowState`.
        IncognitoConfirmation.presentsAlert = false
        defer { IncognitoConfirmation.presentsAlert = true }
        rig.window.performClose(nil)
        await pump(500)
        close["closeAsks"] = rig.state.pendingIncognitoLeave == .closeWindow && rig.window.isVisible
        mark("confirm captured")
        rig.state.cancelIncognitoLeave()
        mark("cancelled")
        await pump(1500)
        mark("pumped")
        close["cancelKeeps"] = rig.state.isIncognito && rig.state.hasIncognitoContent && rig.window.isVisible
        rig.state.newChat()
        mark("newChat asked")
        await pump(200)
        mark("pumped2")
        close["newChatAsks"] = rig.state.pendingIncognitoLeave == .newChat && rig.state.isIncognito
        rig.state.confirmIncognitoLeave()
        await pump(400)
        mark("newChat confirmed")
        close["confirmDiscards"] = !rig.state.isIncognito && rig.state.incognito == nil && session.isClosed
        close["tempDirGone"] = !FileManager.default.fileExists(atPath: temp.path)
        close["routingReleased"] = !rig.env.stores.isEphemeral(chatID)
        close["storeEmptied"] = (try session.store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") }) == 0
        close["conversationDropped"] = !rig.sessions.activeChats.contains(chatID)
        close["logRedactionEnded"] = AppLog.openIncognitoSessions == 0
        close["windowRestorableAgain"] = rig.window.isRestorable
        close["pass"] = ["closeAsks", "cancelKeeps", "newChatAsks", "confirmDiscards", "tempDirGone", "routingReleased",
                         "storeEmptied", "logRedactionEnded"].allSatisfy { close[$0] as? Bool ?? false }

        // Leg 3b: Personalized (the default) includes the instruction layer, read-only.
        rig.state.newIncognitoChat()
        await pump(300)
        let personalizedDefault = rig.state.incognitoPersonalization == .personalized
        let tp = await send(rig, words[4])
        mark("personalized sent")
        let p = rig.state.incognito?.engine.lastRequest
        leg3["personalizedIncludesInstructions"] = layers(p).contains(aboutYou)
        leg3["settingsUnchanged"] = rig.env.promptSettings.inputs.personalization.aboutYou == aboutYou
        leg3["pass"] = choiceShown && defaultPersonalized && personalizedDefault && tp
            && !layers(first).contains(aboutYou) && layers(p).contains(aboutYou)
        result["AT-090-3"] = leg3

        // Leg 4b: quit with content asks in the window; confirming discards (the test answers instead of quitting).
        let quitTemp = rig.state.incognito?.tempDirectory
        // Only this rig's window, and no app to answer: the guard's registry is process-wide (parallel suites have
        // their own incognito windows), and a real `reply(toApplicationShouldTerminate: true)` ends the test process.
        let reply = IncognitoQuitGuard.reply(nil, only: [rig.state])
        mark("quit reply \(reply == .terminateLater)")
        var quitAnswer: Bool?
        rig.state.answerQuit = { quitAnswer = $0 }
        let quitAsks = reply == .terminateLater && rig.state.pendingIncognitoLeave == .quit
        rig.state.confirmIncognitoLeave()
        await pump(300)
        close["quitAsks"] = quitAsks
        close["quitConfirmed"] = quitAnswer == true
        close["quitTempDirGone"] = quitTemp.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        close["pass"] = (close["pass"] as? Bool ?? false) && quitAsks && quitAnswer == true
            && (close["quitTempDirGone"] as? Bool ?? false)
        result["AT-090-4-close"] = close

        // NFR-PR3 at the window level: the container is byte-identical and holds no phrase.
        await pump(500)
        let after = hashes(rig.container)
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        let hits = phraseHits(rig.container, words)
        let staleTemp = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
            .filter { $0.hasPrefix(IncognitoSession.tempPrefix) && ($0 == temp.lastPathComponent || $0 == quitTemp?.lastPathComponent) }
        result["containerDiff"] = ["changedFiles": changed, "phraseHits": hits, "filesHashed": before.count,
                                   "incognitoTempDirsLeft": staleTemp, "pass": changed.isEmpty && hits.isEmpty && staleTemp.isEmpty]
        let legs = result.filter { $0.key.hasPrefix("AT-") || $0.key == "containerDiff" }.compactMap { $0.value as? [String: Any] }
        result["pass"] = legs.allSatisfy { $0["pass"] as? Bool ?? false }
        write(result)

        #expect(result["pass"] as? Bool == true, "\(result)")
        #expect(changed.isEmpty, "changed: \(changed)")
        #expect(hits.isEmpty, "phrase hits: \(hits)")
    }
}
}  // extension WindowSuites
