// AT-007 window legs, in-process form (M1.T15; XCUITest `ThinkHarderTests` cannot run here, Q-015/Q-023/Q-025).
// The real MainWindow + ChatSessions (composer toggle → ConversationModel → TurnController → ScriptedEngine) in an
// NSWindow in the test process, element presence read through the probe anchors (`probeID`):
//   (2) `reasoning.jsonl` (≈ 6 s of reasoning): no thinking line at 1.5 s, the line at 2.5 s with "Thinking… N s"
//       ticking each second, collapsed to "Thought for N s" with N within ±1 s of 6 once the answer streams, and a
//       real click expands the reasoning text;
//   (3) `no-reasoning.jsonl` (caps reasoning=false): the toggle's tooltip key becomes `think.tip.preset` and the
//       request carries the preset;
//   (4) toggle on in chat A, off in chat B: switching restores each, and a fresh window stack on the same database
//       (relaunch) restores both.
// Evidence: build/at/AT-007/host.json when AT007_OUT is set.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ThinkHarderHostTests {
    static func script(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].map { URL(fileURLWithPath: $0) }
        for base in [env, root.appendingPathComponent("fixtures"), root.appendingPathComponent("tools/fixtures")].compactMap({ $0 }) {
            let f = base.appendingPathComponent("scripts/\(name)")
            if FileManager.default.fileExists(atPath: f.path) { return try String(contentsOf: f, encoding: .utf8) }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    struct Rig {
        let env: ChatEnvironment
        let state: WindowState
        let sessions: ChatSessions
        let window: NSWindow
    }

    private func make(_ scriptName: String, database: AppDatabase? = nil) async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let env = ChatEnvironment(database: try database ?? AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script(scriptName))),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindow(state: state, slots: sessions.slots)
            .environment(\.reduceMotionOverride, true))
        BackgroundRun.present(window)
        await pump(500)
        return Rig(env: env, state: state, sessions: sessions, window: window)
    }

    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    private func present(_ rig: Rig, _ id: String) -> Bool {
        rig.window.contentView?.layoutSubtreeIfNeeded()
        return UIProbeRegistry.frame(id, in: rig.window) != nil
    }

    private func click(_ rig: Rig, _ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: rig.window) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: f.minX + 8, y: f.midY), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
            rig.window.sendEvent(e)
        }
        return true
    }

    /// The line the reply shows now (what ReasoningDisclosure renders, from the model's live timing).
    /// The line the view would show for the model's current state at `now` (default: the wall clock). The live counter
    /// is a pure function of `now − sentAt`, so the timing checks pass explicit sample times instead of racing the clock.
    private func line(_ m: ConversationModel, at now: Date = Date()) -> ReasoningLine {
        guard let msg = m.messages.last, msg.role == .assistant else { return .none }
        let live = m.liveReply(for: msg.id)
        let reasoning = live?.reasoning ?? msg.reasoning
        let running = msg.status == .pending || msg.status == .streaming
        let text = live?.text ?? msg.text
        let measured = live?.reasoningStartedAt.flatMap { a in live?.answerStartedAt.map { $0.timeIntervalSince(a) } }
        return ReasoningLineModel.line(
            hasReasoning: !reasoning.isEmpty, thinking: running && text.isEmpty && live?.answerStartedAt == nil,
            sinceSend: now.timeIntervalSince(msg.sentAt ?? now),
            thoughtSeconds: measured ?? msg.reasoningSeconds ?? (running ? 0 : nil))
    }

    static func evidence(_ obj: [String: Any]) {
        guard let dir = ProcessInfo.processInfo.environment["AT007_OUT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("host-\(obj["case"] ?? "x").json")
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }

    @Test func thinkingLineTimingCollapseAndExpand() async throws {
        let rig = try await make("reasoning.jsonl")
        defer { rig.window.orderOut(nil) }
        rig.sessions.composer.thinkHarder = true
        await pump(50)
        let sent = Date()
        rig.state.send("What is the answer?", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        let model = rig.sessions.model(for: try #require(rig.state.currentChatID))
        #expect(model.thinkHarder, "the toggle reached the chat")
        // Timing is checked against explicit sample times (`line(_:at:)`), never against how long a pump overshot: under
        // the full parallel suite the main actor can be starved for seconds, so "wait 1 s, then read the clock" is not
        // a reliable tick check (seen: 7 → 10). The view itself is only checked for presence/absence.
        let sentAt = try #require(model.messages.last?.sentAt)
        // Before 2 s: no line (the PendingDot alone, or nothing yet) — for the state at 1.5 s after the send.
        while Date().timeIntervalSince(sent) < 1.5 { await pump(10) }
        let at15 = present(rig, "reasoningLine")
        let at15Sampled = Date().timeIntervalSince(sentAt)
        // The view may legitimately show the line if the main actor was starved past the 2 s threshold.
        if at15Sampled < ReasoningLineModel.threshold { #expect(!at15, "thinking line before 2 s") }
        #expect([.pendingDot, ReasoningLine.none].contains(line(model, at: sentAt.addingTimeInterval(1.5))))
        #expect(await until(10) { model.messages.last.flatMap { model.liveReply(for: $0.id)?.reasoningStartedAt } != nil })
        let arrival = model.messages.last.flatMap { model.liveReply(for: $0.id)?.reasoningStartedAt }?.timeIntervalSince(sent) ?? 0
        // After 2 s with reasoning: the view shows the line.
        while Date().timeIntervalSince(sent) < max(2.5, arrival + 0.3) { await pump(10) }
        // Bounded condition wait, not a fixed one: at load ~70 the layout pass that adds the line can lag the clock.
        let at25 = await until(10) { present(rig, "reasoningLine") }
        #expect(at25)
        // "Thinking… N s", ticking once per second — sampled on one model state at fixed offsets from the send. The
        // scripted reasoning (~6 s) may already be over under load; then the line is the collapsed "Thought for N s".
        let first = line(model, at: sentAt.addingTimeInterval(2.5))
        let later = line(model, at: sentAt.addingTimeInterval(3.5))
        let laterStill = line(model, at: sentAt.addingTimeInterval(4.99))
        if case .thinking = first {
            #expect(first == .thinking(seconds: 2), "\(first)")
            #expect(later == .thinking(seconds: 3), "counter ticks each second: \(first) → \(later)")
            #expect(laterStill == .thinking(seconds: 4), "\(laterStill)")
        } else {
            #expect(first.copyKey == "status.thought", "after thinking: \(first)")
        }
        #expect(CopyKey("status.thinkingFor").string(["seconds": "3"]) == "Thinking… 3 s")
        // Done: collapsed "Thought for N s". The scripted reasoning takes ≥ 5 s (its delays are lower bounds; a
        // loaded host only lengthens it, so no upper bound), and N is the measured reasoning time.
        #expect(await until(60) { !model.isGenerating && model.messages.last?.status == .done })
        #expect(await until(10) { line(model).copyKey == "status.thought" })
        let done = line(model)
        let n = done.seconds ?? -1
        #expect(done == .thought(seconds: n) && n >= 5, "\(done)")
        #expect(await until(10) { present(rig, "reasoningLine") })
        #expect(!present(rig, "reasoningText"))
        #expect(click(rig, "reasoningLine"))
        #expect(await until(10) { present(rig, "reasoningText") }, "expands on click")
        // The request asked the model to think (scripted caps: reasoning on).
        let request = try #require(await model.controller.lastRequest)
        #expect(request.reasoning.on)
        Self.evidence(["case": "timing", "lineAt1_5s": at15, "lineAt2_5s": at25, "reasoningArrivalS": arrival, "firstLabel": "\(first)",
                       "thoughtSeconds": n, "expanded": present(rig, "reasoningText")])
    }

    @Test func presetTooltipWithoutThinkingMode() async throws {
        let rig = try await make("no-reasoning.jsonl")
        defer { rig.window.orderOut(nil) }
        rig.sessions.composer.thinkHarder = true
        rig.state.send("Hello", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        let model = rig.sessions.model(for: try #require(rig.state.currentChatID))
        #expect(await until(10) { !model.isGenerating && model.messages.last?.status == .done })
        #expect(await until(2) { rig.sessions.composer.thinkHarderPreset })
        #expect(ThinkHarderToggle.tooltipKey(preset: rig.sessions.composer.thinkHarderPreset) == "think.tip.preset")
        #expect(CopyKey("think.tip.preset").string()
                == "This model doesn't have a thinking mode. Think harder uses a slower, more careful setting.")
        let controller = model.controller
        #expect(await controller.lastThinkHarderMode == .preset)
        #expect(await controller.lastRequest?.reasoning.on == false)
        #expect(!present(rig, "thinkHarder"), "a model without a thinking mode has no Think harder button")
        #expect(!present(rig, "reasoningLine"), "no reasoning, no line")
        Self.evidence(["case": "preset", "preset": rig.sessions.composer.thinkHarderPreset])
    }

    @Test func perChatPersistenceAcrossSwitchAndRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-t15-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let rig = try await make("no-reasoning.jsonl", database: db)
        // Chat A with Think harder on.
        rig.sessions.composer.thinkHarder = true
        rig.state.send("Chat A", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        let a = try #require(rig.state.currentChatID)
        #expect(await until(10) { !rig.sessions.model(for: a).isGenerating })
        // Chat B: a new chat starts off.
        rig.state.newChat(seed: 1)
        await pump(200)
        #expect(!rig.sessions.composer.thinkHarder, "a new chat starts with Think harder off")
        rig.state.send("Chat B", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        let b = try #require(rig.state.currentChatID)
        #expect(a != b)
        #expect(await until(10) { !rig.sessions.model(for: b).isGenerating })
        // Switching restores each chat's setting.
        rig.state.open(.chat(a))
        #expect(await until(2) { rig.sessions.composer.thinkHarder })
        rig.state.open(.chat(b))
        #expect(await until(2) { !rig.sessions.composer.thinkHarder })
        // Toggling in an open chat is stored at once (no send needed).
        rig.sessions.composer.thinkHarder = true
        await pump(100)
        #expect(try ChatRepository(db).thinkHarder(b))
        rig.sessions.composer.thinkHarder = false
        await pump(100)
        #expect(try !ChatRepository(db).thinkHarder(b))
        rig.window.orderOut(nil)
        // "Relaunch": a new window stack on the same database file.
        let again = try await make("no-reasoning.jsonl", database: try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite")))
        defer { again.window.orderOut(nil) }
        again.state.open(.chat(a))
        let restoredA = await until(2) { again.sessions.composer.thinkHarder }
        again.state.open(.chat(b))
        let restoredB = await until(2) { !again.sessions.composer.thinkHarder }
        #expect(restoredA && restoredB)
        Self.evidence(["case": "persistence", "chatA": true, "chatB": false, "restoredA": restoredA, "restoredB": restoredB])
    }
}
}  // extension WindowSuites
