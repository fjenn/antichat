// AT-009 in-process context probe (M1.T18). XCUITest is blocked on this Mac (Q-015), so — like WindowProbe /
// PaletteProbe / RendererProbe — the app drives itself through the real window: the composer (ComposerModel.send →
// LiveComposer → WindowState.send → ConversationModel → TurnController → the `-UseScriptedEngine` script, normally
// `long-context.jsonl` with `-FakeContextWindow 4096`) and records
//   (1) whether the `contextUsage` indicator is on screen (hidden by default; shown with `-showContextUsage YES`),
//       its percentage after every turn, and an independent chars/4 estimate of the same request (± 2 pts);
//   (2) the turn at which the summary notice appears, that exactly one `summaryNotice` is on screen afterwards,
//       and that clicking it shows the summarised turns (`summarisedTurn` rows);
//   (3) a prompt larger than the window (set as composer text: the plain-text path, no paste card) is refused:
//       the engine request counter is unchanged, `composerNotice` (`ctx.tooLarge`) is shown and the text stays.
// Writes `<dir>/probe.json` (+ window captures) and quits. DEBUG only (`-ContextProbe <dir>`); run by
// tools/at/at-009-probe.sh.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import Defaults
import SwiftUI

@MainActor
enum ContextProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("ContextProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }

    static func count(_ id: String) -> Int { UIProbeRegistry.frames(id, in: PaletteProbe.window).count }

    /// Sends `text` through the composer and waits for the reply to finish.
    static func turn(_ text: String, sessions: ChatSessions, state: WindowState) async -> Bool {
        sessions.composer.text = text
        guard sessions.composer.send() else { return false }
        let ok = await PaletteProbe.waitUntil(timeout: 60) {
            guard let m = state.currentChatID.map(sessions.model(for:)) else { return false }
            return !m.isGenerating && m.messages.last?.role == .assistant
                && m.messages.last?.status != .pending && m.messages.last?.status != .streaming
        } != nil
        await PaletteProbe.settle(400)  // the usage event and the notice refresh land
        return ok
    }

    /// chars / 4 over what the request carries, computed here from the visible thread (independent of the Harness
    /// estimate): the system turn + every visible message not covered by the summary (+ the summary text).
    static func independentPercent(_ m: ConversationModel, env: ChatEnvironment) -> Double {
        let system = PromptComposer().compose(env.promptSettings.inputs).systemText
        let covered = Set(m.messages.first { $0.role == .systemNote }?.summaryOf ?? [])
        var chars = system.utf8.count
        var count = 1
        for msg in m.messages where (msg.role == .user || msg.role == .assistant) && !covered.contains(msg.id) {
            chars += msg.text.utf8.count
            count += 1
        }
        if !covered.isEmpty, let note = m.messages.first(where: { $0.role == .systemNote }),
           let text = try? env.database.read({ db in
               try MessageRepository.parts(of: note.id, db: db).map(\.body).joined()
           }) {
            chars += text.utf8.count + 360  // the summary envelope (ConversationSummary.contextMessageText)
        }
        let tokens = Double(chars) / 4 + Double(count * 4)
        return tokens / Double(env.contextPolicy.window(for: env.slot())) * 100
    }

    /// Scrolls the transcript up (scroll-wheel events over the conversation column, as a user would; this also
    /// detaches the bottom anchor, IS-7) until an anchor with `id` is on screen.
    static func scrollUntilVisible(_ id: String, in window: NSWindow) async -> Bool {
        let screenHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 0
        let p = CGPoint(x: window.frame.minX + window.frame.width * 0.62, y: screenHeight - window.frame.midY)
        for step in 0..<600 {  // down from wherever the thread is (it may sit detached at the top), then up
            if count(id) > 0 { return true }
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: step < 300 ? -80 : 80, wheel2: 0,
                                   wheel3: 0) else { return false }
            cg.location = p
            if let e = NSEvent(cgEvent: cg) { window.sendEvent(e) }
            await PaletteProbe.settle(30)
        }
        return count(id) > 0
    }

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
        let engine = env.engine as? InProcessScriptedEngine
        let enabled = LaunchOptions.current.showContextUsage ?? Defaults[.showContextUsage]
        var result: [String: Any] = [
            "showContextUsage": enabled, "window": env.contextPolicy.window(for: env.slot()),
            "script": LaunchOptions.current.scriptedEngineScript ?? "real engine",
        ]

        // (1)/(2) Turns until the notice has appeared and one more turn ran after it.
        var turns: [[String: Any]] = []
        var noticeTurn: Int?
        let maxTurns = enabled ? 8 : 1
        for i in 1...maxTurns {
            let ok = await turn("Message number \(i)", sessions: sessions, state: state)
            guard let m = state.currentChatID.map(sessions.model(for:)) else { break }
            let percent = m.contextUsage?.percent ?? -1
            let raw = ((m.contextUsage?.fraction ?? -0.01) * 1000).rounded() / 10
            let independent = independentPercent(m, env: env)
            // The notice sits after the last summarised turn, usually above the visible part of the thread.
            let notices = m.messages.filter { $0.role == .systemNote }.count
            if notices > 0, noticeTurn == nil { noticeTurn = i }
            turns.append([
                "turn": i, "finished": ok, "indicatorOnScreen": count("contextUsage") > 0, "percent": percent,
                "percentUnclamped": raw, "independentPercent": (independent * 10).rounded() / 10,
                "noticesInThread": notices, "engineRequests": engine?.requestCount ?? -1,
                "summaryRows": (try? env.database.read { db in
                    try ChatMessageAdapter.summaryNodes(chatID: m.chatID, db: db).count
                }) ?? -1,
            ])
            if let n = noticeTurn, i >= n + 1 { break }
        }
        result["turns"] = turns
        PaletteProbe.capture("turns.png", dir)
        let preNotice = turns.prefix { ($0["noticesInThread"] as? Int ?? 0) == 0 }
        let percents = preNotice.compactMap { $0["percent"] as? Int }
        let rises = zip(percents, percents.dropFirst()).allSatisfy { $0 < $1 }
        let within2 = turns.allSatisfy { t in
            guard let p = t["percentUnclamped"] as? Double, p >= 0, let q = t["independentPercent"] as? Double else {
                return !enabled
            }
            return abs(p - q) <= 2
        }
        let indicatorOK = enabled ? turns.allSatisfy { $0["indicatorOnScreen"] as? Bool == true } && rises && within2
            : turns.allSatisfy { $0["indicatorOnScreen"] as? Bool == false }
        result["leg1"] = ["pass": indicatorOK, "rises": rises, "within2pts": within2]

        if enabled {
            // (2) one notice; it expands to the summarised turns.
            let onceAfter = turns.drop { ($0["noticesInThread"] as? Int ?? 0) == 0 }.allSatisfy { $0["noticesInThread"] as? Int == 1 }
            let found = await scrollUntilVisible("summaryNotice", in: window)
            let onScreen = count("summaryNotice")
            let collapsedRows = count("summarisedTurn")
            PaletteProbe.click("summaryNotice")
            _ = await PaletteProbe.waitUntil(timeout: 2) { count("summarisedTurn") > 0 }
            await PaletteProbe.settle(300)
            let expandedRows = count("summarisedTurn")
            let note = state.currentChatID.map(sessions.model(for:))?.messages.first { $0.role == .systemNote }
            PaletteProbe.capture("notice-expanded.png", dir)
            let chatID = state.currentChatID ?? ""
            let summaryRows = (try? env.database.read { db in
                try ChatMessageAdapter.summaryNodes(chatID: chatID, db: db).map { ["id": $0.id, "summary_of_ids": $0.coveredIDs] }
            }) ?? []
            result["leg2"] = [
                "pass": noticeTurn != nil && onceAfter && found && onScreen == 1 && collapsedRows == 0
                    && expandedRows >= 2 && expandedRows <= (note?.summaryOf.count ?? -1),
                "noticeTurn": noticeTurn ?? -1, "oneNoticeAfter": onceAfter, "scrolledIntoView": found,
                "noticesOnScreen": onScreen, "rowsCollapsed": collapsedRows,
                "rowsExpanded": expandedRows, "summarisedIDs": note?.summaryOf ?? [], "summaryRows": summaryRows,
            ]
            PaletteProbe.click("summaryNotice")  // collapse again

            // (3) oversize prompt. First let the idle compaction armed by the last turn (2 s idle delay) run, so its
            // summariser request is not counted against the refused send: wait until the request count has been
            // stable for longer than the idle delay (cap 30 s).
            var stableSince = Date(), last = engine?.requestCount ?? -1
            let waitEnd = Date().addingTimeInterval(30)
            while Date() < waitEnd, Date().timeIntervalSince(stableSince) < Double(env.contextPolicy.idleDelay.components.seconds) + 1.5 {
                await PaletteProbe.settle(100)
                let now = engine?.requestCount ?? -1
                if now != last { last = now; stableSince = Date() }
            }
            let before = engine?.requestCount ?? -1
            let replies = state.currentChatID.map(sessions.model(for:))?.messages.count ?? -1
            let big = String(repeating: "lorem ipsum dolor sit amet ", count: 700)
            sessions.composer.text = big
            let sent = sessions.composer.send()
            await PaletteProbe.settle(600)
            let after = engine?.requestCount ?? -1
            PaletteProbe.capture("too-large.png", dir)
            let kept = sessions.composer.text == big
            let noticeShown = count("composerNotice") > 0
            let key = sessions.composer.notice?.key.rawValue ?? ""
            result["leg3"] = [
                "pass": !sent && before == after && kept && noticeShown && key == "ctx.tooLarge"
                    && (state.currentChatID.map(sessions.model(for:))?.messages.count ?? -2) == replies,
                "promptChars": big.count, "estimateTokens": OversizeGuard.tokens(text: big),
                "limit": OversizeGuard.limit(window: env.contextPolicy.window(for: env.slot()),
                                             reservedOutput: env.contextPolicy.reservedOutput),
                "sendAccepted": sent, "engineRequestsBefore": before, "engineRequestsAfter": after,
                "textKeptInComposer": kept, "noticeOnScreen": noticeShown, "noticeKey": key,
            ]
        }
        write(result, dir: dir)
        FileHandle.standardError.write(Data("ContextProbe: done\n".utf8))
    }
}
#endif
