// M7.T03 in-process web search probe (AT-080, AT-250 c1, AT-248 c1, AT-254). XCUITest cannot start on this Mac
// (Q-015), so — like TurnProbe — the app drives its own window. `<dir>/mode` picks the legs (tools/at/at-080-probe.sh
// runs each in a fresh container with `-DefaultsSuite`, so the switch never touches the user's defaults):
//   consent  (script web-plain.jsonl)  c1: onboarding step 4 default On + note; fresh policy = On; the Settings switch
//            path (off → on asks: WebSearchConsent, Not now leaves it off); the + row while off asks, [Turn on] adds
//            the chip; c4: Offline only → chip "Offline", send → answer + `network.offlineForSearch`, no web tool.
//   chip     (script web-search.jsonl, -ScriptedWebSearch YES) c3: chip on → "Searching the web" in the send's next
//            frames, one web_search step, pills only for fetched 1–4 of [1]…[9] (AT-250 c1), hover card, Sources panel
//            rows = the pills (cited first) + More; c2: no Keychain item is read (fresh container, no key exists).
//   reopen   (same container as chip, second launch): pills + Sources panel restored from provenance.
//   readurl  (script web-read.jsonl, -ScriptedWebSearch YES) c3: a pasted URL shows "Read this URL"; accepting forces
//            read_url (first step), the page is the source, the chip is gone after the send.
//   live     (real model `-ChatModel`, live engines; `<dir>/runs`, `<dir>/query`): AT-248 c1 / AT-254 per run:
//            send → activity line on screen, results / fetch+extract (perf log signposts), first answer token, answer
//            complete, rendered pills.
//   vq-*     M7.T16 AT-VQ-M7 captures and journey 12 (VisualQAM7.swift, tools/visual/vq-m7.sh); vq-files-* M6.T21
//            AT-VQ-M6 captures (VisualQAM6.swift, tools/visual/vq-m6.sh).
// Writes `<dir>/probe.json` (+ window captures) and quits. DEBUG only (`-SearchProbe <dir>`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import AntiChatUI
import AppKit
import Defaults
import QuartzCore
import SwiftUI

@MainActor
enum SearchProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("SearchProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    static func present(_ id: String) -> Bool { PaletteProbe.present(id) }
    /// In any window (popovers and sheets are windows of their own).
    static func presentAnywhere(_ id: String) -> Bool { NSApp.windows.contains { UIProbeRegistry.frame(id, in: $0) != nil } }
    static func model(_ state: WindowState, _ sessions: ChatSessions) -> ConversationModel? {
        state.currentChatID.map(sessions.model(for:))
    }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(1500))
        // M7.T15: on a loaded Mac the window can take longer than 1.5 s to appear; wait up to 20 s.
        var found = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" })
        for _ in 0..<74 where found == nil {
            try? await Task.sleep(for: .milliseconds(250))
            found = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" })
        }
        // A window the app keeps ordered out while it runs in the background (no focus steal) still serves the probe.
        if found == nil { found = NSApp.windows.first(where: { $0.title == "AntiChat" }) }
        guard let window = found else {
            write(["error": "no AntiChat window", "windows": NSApp.windows.map { "\($0.title) visible=\($0.isVisible)" }], dir: dir)
            return
        }
        PaletteProbe.window = window
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 860), display: true)
        BackgroundRun.makeKeyAndOrderFront(window)
        BackgroundRun.activate()
        await PaletteProbe.settle(800)
        let mode = ((try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var r: [String: Any] = ["mode": mode, "load_avg": loadAverage()]
        switch mode {
        case "consent": r.merge(await consent(state, sessions, dir), uniquingKeysWith: { $1 })
        case "chip": r.merge(await chip(state, sessions, dir), uniquingKeysWith: { $1 })
        case "reopen": r.merge(await reopen(state, sessions, dir), uniquingKeysWith: { $1 })
        case "readurl": r.merge(await readURL(state, sessions, dir), uniquingKeysWith: { $1 })
        case "live": r.merge(await live(state, sessions, dir), uniquingKeysWith: { $1 })
        case "hint": r.merge(await hint(state, sessions, dir), uniquingKeysWith: { $1 })
        case let m where m.hasPrefix("vq-files-"):  // M6.T21 AT-VQ-M6 captures (VisualQAM6.swift)
            r.merge(await VisualQAM6.run(m, state, sessions, window, dir), uniquingKeysWith: { $1 })
        case let m where m.hasPrefix("vq-"):  // M7.T16 AT-VQ-M7 captures + journey 12 (VisualQAM7.swift)
            r.merge(await VisualQAM7.run(m, state, sessions, window, dir), uniquingKeysWith: { $1 })
        default: r["error"] = "unknown mode \(mode)"
        }
        write(r, dir: dir)
        FileHandle.standardError.write(Data("SearchProbe: done\n".utf8))
    }

    // MARK: Shared

    /// Sends `text`; returns the send instant (for the activity / first-token clocks).
    static func send(_ text: String, _ sessions: ChatSessions) async -> ContinuousClock.Instant {
        sessions.composer.text = text
        await PaletteProbe.settle(80)
        let t0 = ContinuousClock.now
        _ = sessions.composer.send()
        return t0
    }

    static func waitIdle(_ state: WindowState, _ sessions: ChatSessions, timeout: Double = 120) async -> Bool {
        await PaletteProbe.settle(150)
        return await PaletteProbe.waitUntil(timeout: timeout) { !(model(state, sessions)?.isGenerating ?? true) } != nil
    }

    static func last(_ state: WindowState, _ sessions: ChatSessions) -> ConversationModel.Message? {
        model(state, sessions)?.messages.last { $0.role == .assistant }
    }

    static func webItem(_ sessions: ChatSessions) -> ComposerMenuItem? { sessions.composer.menus.addItems.first { $0.id == "web" } }

    /// Pill ids on screen (`citation.<n>[,<m>]`) for n in 1…12.
    static func pillsOnScreen() -> [Int] { (1...12).filter { present("citation.\($0)") } }

    /// AT-248 c1 (M7 at248): every pill VIEW drawn in the window, one entry per pill (a pill cited twice is two pills;
    /// a combined `[1,2]` pill is one pill naming two sources). `checking` = pills still in the pre-verdict state.
    /// The older `pillsOnScreen` missed combined pills and counted a repeated pill once.
    static func renderedPills() -> (settled: [[Int]], checking: Int) {
        guard let window = PaletteProbe.window else { return ([], 0) }
        var settled: [[Int]] = [], checking = 0
        for id in UIProbeRegistry.ids(prefix: "citation.", in: window) {
            let n = UIProbeRegistry.frames(id, in: window).count
            if id.hasSuffix(".checking") { checking += n; continue }
            let sources = id.dropFirst("citation.".count).split(separator: ",").compactMap { Int($0) }
            guard !sources.isEmpty else { continue }
            settled += Array(repeating: sources, count: n)
        }
        return (settled, checking)
    }

    /// Handshake with an external reader of the rendered view (App/UITests/AT248RenderedPillsUITests.swift, attach
    /// mode): `<dir>/handshake` present → wait for `<dir>/reader-ready` before the runs; after each settled run write
    /// `<dir>/settled-<i>` and wait (≤ 120 s, outside every timed leg) for the reader's `<dir>/ack-<i>`.
    static func waitForFile(_ url: URL, timeout: Double) async -> Bool {
        await PaletteProbe.waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) } != nil
    }
    static func rowsOnScreen() -> [Int] { (1...12).filter { present("sourcesRow.\($0)") } }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }

    static func ms(_ d: Duration) -> Double { (PaletteProbe.seconds(d) * 1000 * 10).rounded() / 10 }

    // MARK: consent (c1, c4)

    static func consent(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let policy = NetworkPolicyStore.shared
        let consent = WebSearchConsent.shared
        var c1: [String: Any] = [:], c4: [String: Any] = [:]
        // Onboarding step 4: the switch defaults to On and carries the note (the deck strings).
        let onb = OnboardingModel(profile: nil, catalog: nil, freeBytes: 0)
        c1["onboardingDefaultOn"] = onb.searchOn
        c1["onboardingLabel"] = CopyKey("onb.4.search.label").string()
        c1["onboardingNote"] = CopyKey("onb.4.search.note").string()
        c1["freshPolicyOn"] = policy.storedValue(.search)
        c1["menuRowAvailable"] = webItem(sessions)?.state == .enabled
        // The Settings switch: off, then on → the consent sheet (Not now leaves it off).
        policy.setEnabled(.search, false)
        await PaletteProbe.settle(300)
        c1["menuRowNeedsConsentWhenOff"] = webItem(sessions)?.state == .needsConsent
        var settingsAnswers: [Bool] = []
        consent.request(from: .settings) { settingsAnswers.append($0) }
        c1["settingsAsks"] = consent.presented == .settings
        consent.answer(false)
        c1["notNowLeavesOff"] = settingsAnswers == [false] && !policy.storedValue(.search)
        // The composer's + row while off: the sheet in the main window names the engines; [Turn on] adds the chip.
        if let web = webItem(sessions) { sessions.composer.menus.pickAdd(web) }
        await PaletteProbe.settle(700)
        c1["sheetShown"] = presentAnywhere("search.consentSheet")
        c1["engines"] = consent.engines
        c1["bodyNamesEnginesAndOnlySearchWords"] = consent.engines.contains("DuckDuckGo") && consent.engines.contains("Wikipedia")
            && !consent.engines.contains("Google")
            && CopyText(CopyKey("search.consent.body"), ["engines": consent.engines]).string.contains("Never your chats or your name.")
        PaletteProbe.capture("consent-sheet.png", dir)
        consent.answer(true)  // [Turn on] (the sheet's button calls exactly this)
        await PaletteProbe.settle(500)
        c1["turnedOn"] = policy.storedValue(.search)
        c1["chipAdded"] = sessions.composer.menus.chips.chips.map(\.id) == ["web"]
        // Offline only forces the switch off (row + chip state), the stored value comes back after.
        policy.offlineOnly = true
        await PaletteProbe.settle(400)
        c4["chipOffline"] = sessions.composer.menus.chips.chips.first?.item.state == .offline && present("toolChipOffline.web")
        PaletteProbe.capture("offline-chip.png", dir)
        _ = await send("What's the latest macOS version?", sessions)
        let idle = await waitIdle(state, sessions)
        await PaletteProbe.settle(400)
        let m = last(state, sessions)
        c4["finished"] = idle && m?.status == .done
        c4["answered"] = !(m?.text ?? "").isEmpty
        c4["notice"] = m?.activities.contains { $0.kind == .notice && $0.tool == "network.offlineForSearch" } == true
            && present("activityNotice-network.offlineForSearch")
        c4["noWebStep"] = m?.activities.contains { $0.kind == .tool } == false
        c4["noPills"] = pillsOnScreen().isEmpty
        PaletteProbe.capture("offline-answer.png", dir)
        policy.offlineOnly = false
        await PaletteProbe.settle(300)
        c1["storedValueBackAfterOfflineOnly"] = policy.storedValue(.search)
        let pass1 = ["onboardingDefaultOn", "freshPolicyOn", "menuRowAvailable", "menuRowNeedsConsentWhenOff", "settingsAsks",
                     "notNowLeavesOff", "sheetShown", "bodyNamesEnginesAndOnlySearchWords", "turnedOn", "chipAdded",
                     "storedValueBackAfterOfflineOnly"].allSatisfy { c1[$0] as? Bool == true }
        let pass4 = ["chipOffline", "finished", "answered", "notice", "noWebStep", "noPills"].allSatisfy { c4[$0] as? Bool == true }
        return ["c1": c1, "c4": c4, "pass": pass1 && pass4]
    }

    // MARK: chip (c3, AT-250 c1)

    static func chip(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        var c3: [String: Any] = [:]
        guard let web = webItem(sessions), web.state == .enabled else { return ["error": "no Web search row", "pass": false] }
        sessions.composer.menus.pickAdd(web)
        await PaletteProbe.settle(200)
        let t0 = await send("What's the latest macOS version?", sessions)
        // The "Searching the web" line: first frame it is on screen.
        // The "Searching the web" line: the first committed frame that has it on screen.
        let actAt = await PaletteProbe.waitUntil(timeout: 5) {
            guard let id = last(state, sessions)?.id else { return false }
            return present("activityLine-web-\(id)")
        }
        c3["activityMs"] = actAt.map { _ in ms(ContinuousClock.now - t0) }
        _ = await waitIdle(state, sessions)
        await PaletteProbe.settle(800)
        guard let m = last(state, sessions) else { return ["error": "no reply", "pass": false] }
        let steps = m.activities.filter { $0.kind == .tool }
        c3["webSteps"] = steps.filter { $0.tool == "web_search" }.count
        c3["stepDone"] = steps.first?.state == .done
        c3["activityLabel"] = steps.first.map { _ in present("activityLine-web-\(m.id)") } ?? false
        let fetched = Set(m.sources.filter(\.fetched).map(\.n))
        let pills = pillsOnScreen()
        c3["sources"] = m.sources.map(\.n)
        c3["fetched"] = fetched.sorted()
        c3["pills"] = pills
        c3["everyPillFetched"] = !pills.isEmpty && pills.allSatisfy(fetched.contains)
        c3["noPillForUnfetched"] = (5...9).allSatisfy { !present("citation.\($0)") }
        PaletteProbe.capture("answer-pills.png", dir)
        // Hover card: move the pointer onto the first pill (real mouse-moved events through the window).
        var hover = false
        if let f = UIProbeRegistry.frame("citation.1", in: PaletteProbe.window), let w = PaletteProbe.window {
            w.acceptsMouseMovedEvents = true
            let p = CGPoint(x: f.midX, y: f.midY)
            for dy in [0.0, 0.5, 0.0] {
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: p.x, y: p.y + dy), modifierFlags: [], timestamp: 0,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    w.sendEvent(e)
                }
                await PaletteProbe.settle(120)
            }
            hover = await PaletteProbe.waitUntil(timeout: 2) { presentAnywhere("citationHoverCard") } != nil
            if hover { PaletteProbe.capture("hover-card.png", dir) }
        }
        c3["hoverCard"] = hover
        // The Sources panel: every fetched page, cited first, then More; rows = pills.
        let clicked = PaletteProbe.click("sourcesButton")
        await PaletteProbe.settle(900)
        let rows = rowsOnScreen()
        c3["sourcesButton"] = clicked
        c3["panelRows"] = rows
        c3["panelListsEveryFetched"] = Set(rows) == fetched
        c3["pillsMatchPanel"] = Set(pills).isSubset(of: Set(rows))
        c3["moreSection"] = Set(pills) == fetched || present("sourcesMore")
        PaletteProbe.capture("sources-panel.png", dir)
        // c2: works with no key (fresh container; the built-in engines need none; nothing reads the Keychain here).
        let c2: [String: Any] = ["noKeyNeeded": true, "note": "fresh container, keyless engines; BYO-key half = AT-251 (M11, D-026)"]
        try? state.currentChatID.map { try Data($0.utf8).write(to: dir.appendingPathComponent("chat-id")) }
        let pass = (c3["webSteps"] as? Int) == 1 && ["stepDone", "everyPillFetched", "noPillForUnfetched", "sourcesButton",
                                                     "panelListsEveryFetched", "pillsMatchPanel"].allSatisfy { c3[$0] as? Bool == true }
            && ((c3["activityMs"] as? Double) ?? 9999) <= 300
        return ["c2": c2, "c3": c3, "hover_pass": hover, "pass": pass]
    }

    // MARK: reopen (provenance restored after a relaunch)

    static func reopen(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let chatID = (try? String(contentsOf: dir.deletingLastPathComponent().appendingPathComponent("probe-chip/chat-id"), encoding: .utf8))
            ?? (try? String(contentsOf: dir.appendingPathComponent("chat-id"), encoding: .utf8))
        guard let chatID else { return ["error": "no chat id from the chip leg", "pass": false] }
        state.open(.chat(chatID))
        await PaletteProbe.settle(1500)
        let m = last(state, sessions)
        let pills = pillsOnScreen()
        _ = PaletteProbe.click("sourcesButton")
        await PaletteProbe.settle(900)
        let rows = rowsOnScreen()
        PaletteProbe.capture("reopened.png", dir)
        let fetched = Set(m?.sources.filter(\.fetched).map(\.n) ?? [])
        let pass = !pills.isEmpty && pills.allSatisfy(fetched.contains) && Set(rows) == fetched
        return ["pills": pills, "panelRows": rows, "sourcesRestored": m?.sources.count ?? 0, "pass": pass]
    }

    // MARK: readurl (c3 Read this URL)

    static func readURL(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        var r: [String: Any] = [:]
        let url = "https://example.org/article"
        sessions.composer.text = "Summarise \(url) for me"
        await PaletteProbe.settle(500)
        r["suggestionShown"] = present("readURLSuggestion")
        PaletteProbe.capture("read-url-suggestion.png", dir)
        if !PaletteProbe.click("readURLSuggestion") { sessions.composer.menus.chips.acceptReadURL() }
        await PaletteProbe.settle(300)
        r["chip"] = sessions.composer.menus.chips.chips.map(\.id)
        _ = sessions.composer.send()
        _ = await waitIdle(state, sessions)
        await PaletteProbe.settle(600)
        let m = last(state, sessions)
        let reqs = (sessions.environment.engine as? InProcessScriptedEngine).map { _ in true } ?? false
        r["scripted"] = reqs
        r["firstStepReadURL"] = m?.activities.first { $0.kind == .tool }?.tool == "read_url"
        r["source"] = m?.sources.first?.url
        r["pageIsSource"] = m?.sources.first?.url == url && m?.sources.first?.fetched == true
        r["pill"] = present("citation.1")
        r["chipGoneAfterSend"] = !sessions.composer.menus.chips.chips.contains { $0.id == "readUrl" }
        PaletteProbe.capture("read-url-answer.png", dir)
        r["pass"] = r["suggestionShown"] as? Bool == true && (r["chip"] as? [String]) == ["readUrl"]
            && ["firstStepReadURL", "pageIsSource", "pill", "chipGoneAfterSend"].allSatisfy { r[$0] as? Bool == true }
        return r
    }

    // MARK: hint (M7.T05, AT-228 c1–c4)

    static func hint(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let policy = NetworkPolicyStore.shared, consent = WebSearchConsent.shared
        var r: [String: Any] = [:]
        policy.setEnabled(.search, false)
        Defaults[.suggestWebSearch] = true
        await PaletteProbe.settle(300)
        func ask(_ q: String) async -> ConversationModel.Message? {
            _ = await send(q, sessions)
            _ = await waitIdle(state, sessions)
            await PaletteProbe.settle(900)
            return last(state, sessions)
        }
        // c1: local answer + the hint, exact text, two buttons.
        state.newChat(); await PaletteProbe.settle(400)
        var m = await ask("What's the latest macOS version?")
        r["c1_answered"] = !(m?.text ?? "").isEmpty
        r["c1_hint"] = m?.freshHint == .offer && present("freshHint") && present("freshHint.on") && present("freshHint.later")
        r["c1_text"] = CopyKey("hint.fresh").string()
        PaletteProbe.capture("hint.png", dir)
        // c2: [Turn on web search] opens consent; nothing changes until it is accepted.
        _ = PaletteProbe.click("freshHint.on")
        await PaletteProbe.settle(600)
        r["c2_consentOpens"] = consent.presented == .main && presentAnywhere("search.consentSheet")
        consent.answer(false)
        await PaletteProbe.settle(300)
        r["c2_stillOff"] = !policy.storedValue(.search)
        // c3: [Not now] hides it in this chat only; the setting hides it everywhere.
        // [Not now]: the button's own action (a synthetic click after the sheet closed stalled the probe's main
        // thread on this Mac; the button is covered by FreshnessHintUITests, pending Q-015).
        model(state, sessions)?.freshHintLater()
        await PaletteProbe.settle(600)
        r["c3_marker"] = ((try? ChatRepository(sessions.environment.database).toolsJSON(state.currentChatID ?? "")) ?? nil) ?? ""
        r["c3_hiddenNow"] = !present("freshHint")
        m = await ask("Any news on interest rates today?")
        r["c3_staysHiddenInChat"] = m?.freshHint == nil && !present("freshHint")
        state.newChat(); await PaletteProbe.settle(400)
        m = await ask("What's the weather in Lisbon today?")
        r["c3_otherChatShows"] = m?.freshHint == .offer
        Defaults[.suggestWebSearch] = false
        state.newChat(); await PaletteProbe.settle(400)
        m = await ask("What's the weather in Lisbon today?")
        r["c3_settingOffHides"] = m?.freshHint == nil
        Defaults[.suggestWebSearch] = true
        // c4: offline → the offline text, no buttons.
        policy.offlineOnly = true
        state.newChat(); await PaletteProbe.settle(400)
        m = await ask("What's the weather in Lisbon today?")
        r["c4_offline"] = m?.freshHint == .offline && present("freshHint") && !present("freshHint.on")
        PaletteProbe.capture("hint-offline.png", dir)
        policy.offlineOnly = false
        r["pass"] = r.filter { $0.key.hasPrefix("c") && !$0.key.hasSuffix("_text") && !$0.key.hasSuffix("_marker")
            }.allSatisfy { $0.value as? Bool == true }
        return r
    }

    // MARK: live (AT-248 c1, AT-254)

    static func live(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let runs = Int((try? String(contentsOf: dir.appendingPathComponent("runs"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 20
        let queries = ((try? String(contentsOf: dir.appendingPathComponent("queries"), encoding: .utf8)) ?? "What's the latest macOS version?")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var rows: [[String: Any]] = []
        let handshake = FileManager.default.fileExists(atPath: dir.appendingPathComponent("handshake").path)
        // The sandboxed UI-test runner writes its files in its own container (`<dir>/reader-dir` names it).
        let readerDir = (try? String(contentsOf: dir.appendingPathComponent("reader-dir"), encoding: .utf8))
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true) } ?? dir
        if handshake, !(await waitForFile(readerDir.appendingPathComponent("reader-ready"), timeout: 900)) {
            return ["error": "handshake: no reader-ready within 900 s"]
        }
        // Warm the model once (not measured; the AT measures a search turn, not a cold load).
        state.newChat()
        await PaletteProbe.settle(500)
        _ = await send("Say OK.", sessions)
        _ = await waitIdle(state, sessions, timeout: 600)
        for i in 0..<runs {
            state.newChat()
            await PaletteProbe.settle(600)
            guard let web = webItem(sessions), web.state == .enabled else { rows.append(["run": i, "error": "web row not available"]); continue }
            if sessions.composer.menus.chips.chips.isEmpty { sessions.composer.menus.pickAdd(web) }
            await PaletteProbe.settle(150)
            let q = queries[i % queries.count]
            let t0 = await send(q, sessions)
            var activityMs: Double?, firstTokenS: Double?
            let deadline = ContinuousClock.now + .seconds(180)
            while ContinuousClock.now < deadline {
                let m = last(state, sessions)
                if activityMs == nil, m?.activities.contains(where: { WebSearchTools.names.contains($0.tool) }) == true {
                    await TurnProbe.atNextCommit()
                    activityMs = ms(ContinuousClock.now - t0)
                }
                if firstTokenS == nil, let m,
                   !(model(state, sessions)?.liveReply(for: m.id)?.text.isEmpty ?? true) || !m.text.isEmpty {
                    firstTokenS = PaletteProbe.seconds(ContinuousClock.now - t0)
                }
                if !(model(state, sessions)?.isGenerating ?? true) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let completeS = PaletteProbe.seconds(ContinuousClock.now - t0)
            // M7 bars: the citation checks settle after the final write (pills in the checking state until then).
            var settledS: Double?
            while ContinuousClock.now < deadline + .seconds(120) {
                if last(state, sessions)?.citationsChecking != true { settledS = PaletteProbe.seconds(ContinuousClock.now - t0); break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // M7 at248: the rendered view must show the verdict too — wait (hard limit 30 s) until no pill is drawn in
            // the checking state and the pill set is stable for 1 s; only settled pills count.
            var uiSettledS: Double?
            var stableSince = ContinuousClock.now, lastSeen: [[Int]] = renderedPills().settled
            let uiDeadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < uiDeadline {
                let now = renderedPills()
                if now.settled != lastSeen { lastSeen = now.settled; stableSince = ContinuousClock.now }
                if settledS != nil, now.checking == 0, ContinuousClock.now - stableSince >= .seconds(1) {
                    uiSettledS = PaletteProbe.seconds(ContinuousClock.now - t0); break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let drawn = renderedPills()
            let m = last(state, sessions)
            // M7 bars (T1 latency profile): the answer step's engine usage and the turn's reasoning time.
            let rec = m.flatMap { id in try? sessions.environment.database.read { try MessageRecord.fetchOne($0, key: id.id) } }
            let callParts = m.flatMap { try? MessageRepository(sessions.environment.database).parts(of: $0.id).filter { $0.kind == .toolCall } } ?? []
            let calls = callParts.count
            let pills = pillsOnScreen()
            let step = m?.activities.first { WebSearchTools.names.contains($0.tool) }
            // Diagnostics (M7 at248): the model's own text and the evidence per source, for an offline attach replay.
            var diag: [String: Any] = [:]
            if let c = model(state, sessions)?.debugController {
                diag["model_text"] = await c.lastModelText ?? ""
                diag["attached"] = await c.lastAttached
                diag["spread_added"] = await c.lastSpread
                if let g = await c.lastGrounding { diag["grounding_uncited"] = g.uncited; diag["grounding_checked"] = g.checked }
            }
            // M7 final: the model's tool calls (its queries) and every source's url / fetched flag (retrieval analysis).
            diag["tool_calls"] = callParts.map(\.body)
            diag["sources"] = (m?.sources ?? []).map { ["n": $0.n, "url": $0.url, "title": $0.title, "fetched": $0.fetched] as [String: Any] }
            if let c = model(state, sessions)?.debugController {
                diag["evidence"] = Dictionary(uniqueKeysWithValues: await c.lastEvidence.map { (String($0.key), $0.value) })
            }
            let pillLabels: [String] = drawn.settled.map { $0.map(String.init).joined(separator: ",") }
            let distinct: Int = Set(drawn.settled.flatMap { $0 }).count
            let fetchedNs: [Int] = m?.sources.filter(\.fetched).map(\.n) ?? []
            let pillFields: [String: Any] = [
                "pills_rendered": drawn.settled.count, "pills": pillLabels, "pill_sources_distinct": distinct,
                "pills_checking_left": drawn.checking, "ui_settled_s": uiSettledS ?? -1, "pill_ids_legacy": pills,
                "window_visible": PaletteProbe.window?.isVisible ?? false,
                "window_alpha": Double(PaletteProbe.window?.alphaValue ?? 0), "fetched_ns": fetchedNs,
                "text_full": m?.text ?? "",
            ]
            var row: [String: Any] = [
                "run": i, "query": q, "status": m?.status.rawValue ?? "none", "activity_ms": activityMs ?? -1,
                "first_token_s": firstTokenS ?? -1, "complete_s": completeS,
                "sources": m?.sources.count ?? 0, "fetched": m?.sources.filter(\.fetched).count ?? 0,
                "step_state": step?.state.rawValue ?? "none", "step_seconds": step?.seconds ?? -1,
                "chars": m?.text.count ?? 0, "load_avg": loadAverage(), "settled_s": settledS ?? -1,
                "answer_prompt_tokens": rec?.usage?.promptTokens ?? -1, "answer_cached_tokens": rec?.usage?.cachedTokens ?? -1,
                "answer_completion_tokens": rec?.usage?.completionTokens ?? -1, "answer_ttft_ms": rec?.usage?.ttftMs ?? -1,
                "reasoning_s": (rec?.provenance?.reasoningMs ?? 0) / 1000, "tok_per_s": rec?.provenance?.tokPerS ?? -1,
                "tool_calls": calls, "text": String((m?.text ?? "").prefix(600)),
            ]
            row.merge(pillFields, uniquingKeysWith: { $1 })
            row["diag"] = diag
            rows.append(row)
            if i < 3, !handshake { PaletteProbe.capture("live-\(i).png", dir) }
            if handshake {
                try? JSONSerialization.data(withJSONObject: rows.last ?? [:], options: [.prettyPrinted, .sortedKeys])
                    .write(to: dir.appendingPathComponent("settled-\(i).json"))
                if !(await waitForFile(readerDir.appendingPathComponent("ack-\(i)"), timeout: 120)) { rows[rows.count - 1]["reader"] = "no ack" }
            }
            try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("runs.partial.json"))
        }
        return ["runs": rows, "chat_model": UserDefaults.standard.string(forKey: "ChatModel") ?? "default"]
    }

    static func write(_ obj: [String: Any], dir: URL) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        try? data.write(to: dir.appendingPathComponent("probe.json"))
    }
}
#endif
