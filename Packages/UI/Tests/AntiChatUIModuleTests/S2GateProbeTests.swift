// AT-M1-S2 in-process legs (M1.T01 steps 4.3–4.4; A-M1-T01a). The gate's own forms need the app window (idle
// `footprint` of `make run`) and XCUITest (`S2ShellParityTests/testRealModelStreamingRate`), and neither runs from a
// worktree agent's sandbox (Q-015, Q-025). These stand-ins host the real MainWindow + ChatSessions (the app's
// composition: TurnController, ConversationModel's 30 Hz coalescing, the streaming Markdown renderer) in an
// NSWindow in the test process:
//   - streaming rate (b): replies streamed at the engine's measured decode pace (chat-9b-q4 at the T1 cap, 101.6
//     tok/s, M1.T05 bench smoke → 10 ms per token) through a timing decorator; engine rate = tokens over the first →
//     last delta, renderer rate = the same tokens over the first → last reveal apply (`MarkdownProbe`, the
//     `rendererApply` instrumentation of M1.T09). Pass: renderer ≥ 97 % of engine.
//   - idle footprint (c): a 50-message chat open in the window, 10 s idle, then this process's `phys_footprint`
//     (TASK_VM_INFO, what `footprint` reports). The test process also carries the test runner, so it is an upper
//     bound of the app's own footprint `[PROXY]`.
// Runs only with `AT_M1_S2_OUT` set (artefacts `$AT_M1_S2_OUT/{bench.json,footprint.json}`; AT_M1_S2_RUNS, default 5).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import Darwin
import QuartzCore
import SwiftUI
import Synchronization
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct S2GateProbeTests {
    /// Timestamps every text delta as it leaves the engine (the engine side of the rate comparison).
    final class TimingEngine: EngineService {
        let inner: InProcessScriptedEngine
        let stamps = Mutex<[Double]>([])
        init(_ inner: InProcessScriptedEngine) { self.inner = inner }

        func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
        func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
            await inner.warmup(slot, onLifecycle: onLifecycle)
        }
        func cancel(_ requestID: UUID) { inner.cancel(requestID) }
        func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
            let source = inner.chat(request, onLifecycle: onLifecycle)
            let (out, cont) = AsyncThrowingStream<EngineEvent, Error>.makeStream(bufferingPolicy: .unbounded)
            let task = Task { [self] in
                do {
                    for try await e in source {
                        if case .textDelta = e { stamps.withLock { $0.append(CACurrentMediaTime()) } }
                        cont.yield(e)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
            return out
        }
    }

    static let tokenMs = 10  // ≈ 101.6 tok/s, chat-9b-q4 decode at the T1 cap (build/at/M1-T05-bench-smoke/)
    static let words = 600

    private static func script() -> String {
        let vocab = ["The", "market", "opens", "at", "dawn,", "and", "every", "stall", "counts", "its", "coins", "twice."]
        var lines: [String] = []
        for i in 0..<words {
            let w = vocab[i % vocab.count]
            let v = i == 0 ? w : (i % 60 == 59 ? "\\n\\n" + w : " " + w)  // JSON-escaped paragraph break
            lines.append(#"{"t":"textDelta","v":"\#(v)","delayMs":\#(tokenMs)}"#)
        }
        return lines.joined(separator: "\n")
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

    private struct Rig {
        let env: ChatEnvironment
        let engine: TimingEngine
        let state: WindowState
        let sessions: ChatSessions
        let window: NSWindow
    }

    private func make() async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let engine = TimingEngine(InProcessScriptedEngine(script: try EngineScript(text: Self.script())))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        let host = NSHostingView(rootView: MainWindow(state: state, slots: sessions.slots))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
                              defer: false)
        window.title = "AntiChat"
        window.isReleasedWhenClosed = false
        window.contentView = host
        BackgroundRun.present(window)
        await pump(600)
        return Rig(env: env, engine: engine, state: state, sessions: sessions, window: window)
    }

    private static func write(_ name: String, _ obj: [String: Any]) {
        guard let dir = ProcessInfo.processInfo.environment["AT_M1_S2_OUT"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url.appendingPathComponent(name))
        }
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A measurement for the gate run only (timing-sensitive): enabled when AT_M1_S2_OUT is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AT_M1_S2_OUT"] != nil))
    func rendererKeepsEngineSpeedThenIdleFootprint() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        let runs = Int(ProcessInfo.processInfo.environment["AT_M1_S2_RUNS"] ?? "") ?? 5
        var rows: [[String: Double]] = []
        for i in 0..<runs {
            let probe = MarkdownProbe()
            MarkdownProbe.current = probe
            rig.engine.stamps.withLock { $0 = [] }
            // Each reply in a fresh chat (the probe instruments the renderer binders created while it is installed).
            if i > 0 {
                rig.state.newChat(seed: 1)
                await pump(400)
            }
            rig.state.send("Walk me through a market day (\(i)).", reduceMotion: true, turn: rig.sessions.slots.startTurn)
            let id = try #require(rig.state.currentChatID)
            let model = rig.sessions.model(for: id)
            #expect(await until(60) { !model.isGenerating && model.messages.last?.status == .done })
            // Let the reveal drain (it trails the stream by ≤ catchUp).
            await pump(1200)
            MarkdownProbe.current = nil
            let stamps = rig.engine.stamps.withLock { $0 }
            let applies = probe.applies.filter { $0.words > 0 }
            guard let e0 = stamps.first, let e1 = stamps.last, let a0 = applies.first?.time, let a1 = applies.last?.time,
                e1 > e0, a1 > a0
            else {
                Issue.record("run \(i): no timing (stamps \(stamps.count), applies \(applies.count))")
                continue
            }
            let tokens = Double(stamps.count)
            let engineRate = (tokens - 1) / (e1 - e0)
            let rendererRate = (tokens - 1) / (a1 - a0)
            rows.append(["engine_tok_s": engineRate, "renderer_tok_s": rendererRate, "ratio": rendererRate / engineRate,
                         "tokens": tokens, "revealed_words": Double(applies.reduce(0) { $0 + $1.words }),
                         "reveal_tail_ms": (a1 - e1) * 1000,
                         // Throughput while both run (excludes the fixed end-of-reply drain of the reveal clock).
                         "shown_at_last_token": Double(applies.filter { $0.time <= e1 }.reduce(0) { $0 + $1.words })
                             / Double(max(1, applies.reduce(0) { $0 + $1.words })), "first_reveal_after_first_token_ms": (a0 - e0) * 1000])
        }
        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        let ratio = median(rows.map { $0["ratio"]! })
        let bench: [String: Any] = [
            "method": "in-process MainWindow + ChatSessions, scripted engine at the measured chat-9b-q4 T1 decode pace [PROXY]",
            "token_ms": Self.tokenMs, "words": Self.words, "runs": rows,
            "median_engine_tok_s": median(rows.map { $0["engine_tok_s"]! }),
            "median_renderer_tok_s": median(rows.map { $0["renderer_tok_s"]! }),
            "median_ratio": ratio, "bar": 0.97, "pass": ratio >= 0.97,
            "median_shown_at_last_token": median(rows.map { $0["shown_at_last_token"]! }),
        ]
        Self.write("bench.json", bench)
        #expect(rows.count == runs)
        #expect(ratio >= 0.97, "renderer \(ratio) of engine")

        // (c) idle: a 50-message chat open, 10 s with nothing happening.
        let service = ChatListService(environment: rig.env)
        let chat = try service.create(title: "Fifty")
        for n in 0..<25 {
            try service.appendUserMessage(chat.id, text: "Question \(n): how does the market keep its accounts?")
            try service.appendAssistantMessage(chat.id, text: String(
                repeating: "The **ledger** is balanced every evening; `coins` are counted twice. ", count: 6))
        }
        rig.state.open(.chat(chat.id))
        await pump(2000)
        #expect(rig.sessions.model(for: chat.id).messages.count == 50)
        await pump(10_000)
        let bytes = Self.physFootprint()
        let mb = Double(bytes) / 1_048_576
        Self.write("footprint.json", [
            "method": "phys_footprint (TASK_VM_INFO) of the test process hosting MainWindow with a 50-message chat, after 10 s idle [PROXY: includes the test runner]",
            "phys_footprint": bytes, "phys_footprint_mb": mb, "bar_mb": 200, "pass": mb <= 200,
            "messages": 50,
        ])
        #expect(mb <= 200, "phys_footprint \(mb) MB")
    }
}
}  // extension WindowSuites
