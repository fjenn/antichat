// M1.T06 AT-004 (unit leg) + definition of done: the TurnState table (every transition, including Stop during
// prefill, Stop while queued and an engine crash in each state), the status line rules (NFR-U3/U4), and the
// TurnController against the in-process ScriptedEngine and an in-memory database: send → stream → done, Stop
// keeps exactly the persisted partial text, the 300 ms grace when the engine ignores Cancel, crash/engine
// error → interrupted with `engine.restarted`, Retry → sibling version, Edit → user sibling, launch sweep.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

// MARK: - State table

@Suite("TurnControllerTests.state") struct TurnStateTableTests {
    static let inputs: [TurnInput] = [
        .send, .loadStarted, .loadReady, .prefillProgress, .content, .toolCallFragment, .usage,
        .done(.stop), .done(.cancelled), .done(.length), .done(.toolCalls), .failure(hadContent: false),
        .failure(hadContent: true), .stop, .finalized(.done), .finalized(.interrupted(errorCode: nil)),
        .finalized(.failed(errorCode: "engine.restarted")),
    ]

    /// The full table, written out: (phase, input) → next. Anything not listed must be rejected (nil).
    static let table: [TurnPhase: [TurnInput: TurnPhase]] = {
        let running: [TurnPhase] = [.queued, .loading, .prefill, .streaming, .toolCall]
        var t: [TurnPhase: [TurnInput: TurnPhase]] = [:]
        for p in TurnPhase.allCases { t[p] = [:] }
        for p in [TurnPhase.idle, .interrupted, .error] { t[p]![.send] = .queued }
        for p in running {
            t[p]![.stop] = .finalizing
            t[p]![.usage] = p
            t[p]![.content] = .streaming
            t[p]![.toolCallFragment] = .toolCall
            for r in [FinishReason.stop, .cancelled, .length, .toolCalls] { t[p]![.done(r)] = .finalizing }
            t[p]![.failure(hadContent: false)] = .finalizing
            t[p]![.failure(hadContent: true)] = .finalizing
        }
        t[.queued]![.loadStarted] = .loading
        t[.prefill]![.loadStarted] = .loading
        t[.loading]![.loadReady] = .prefill
        t[.queued]![.loadReady] = .prefill
        for p in [TurnPhase.queued, .loading, .prefill] { t[p]![.prefillProgress] = .prefill }
        t[.finalizing]![.finalized(.done)] = .idle
        t[.finalizing]![.finalized(.interrupted(errorCode: nil))] = .interrupted
        t[.finalizing]![.finalized(.failed(errorCode: "engine.restarted"))] = .error
        return t
    }()

    @Test func everyTransitionMatchesTheTable() {
        var checked = 0
        for phase in TurnPhase.allCases {
            for input in Self.inputs {
                let expected = Self.table[phase]?[input]
                #expect(TurnState.next(phase, input) == expected, "\(phase) + \(input)")
                checked += 1
            }
        }
        #expect(checked == TurnPhase.allCases.count * Self.inputs.count)
    }

    @Test func stopDuringPrefillAndWhileQueuedInterrupts() {
        #expect(TurnState.next(.prefill, .stop) == .finalizing)
        #expect(TurnState.next(.queued, .stop) == .finalizing)
        #expect(TurnState.outcome(stopped: true, finish: nil, errorCode: nil, hadContent: false) == .interrupted(errorCode: nil))
        #expect(TurnState.next(.finalizing, .finalized(.interrupted(errorCode: nil))) == .interrupted)
    }

    @Test func stopIsRejectedWhenNothingRuns() {
        for p in [TurnPhase.idle, .interrupted, .error, .finalizing] { #expect(TurnState.next(p, .stop) == nil) }
    }

    @Test func engineCrashInEachState() {
        for p in [TurnPhase.queued, .loading, .prefill, .streaming, .toolCall] {
            for had in [false, true] { #expect(TurnState.next(p, .failure(hadContent: had)) == .finalizing, "\(p)") }
        }
        // Before content → failed (ErrorInline); after content → interrupted with the code (R-004 AC3).
        #expect(TurnState.outcome(stopped: false, finish: nil, errorCode: "engine.restarted", hadContent: false)
            == .failed(errorCode: "engine.restarted"))
        #expect(TurnState.outcome(stopped: false, finish: nil, errorCode: "engine.restarted", hadContent: true)
            == .interrupted(errorCode: "engine.restarted"))
        #expect(TurnState.outcome(stopped: true, finish: nil, errorCode: "engine.restarted", hadContent: false)
            == .interrupted(errorCode: "engine.restarted"))
        #expect(TurnState.outcome(stopped: false, finish: .cancelled, errorCode: nil, hadContent: true) == .interrupted(errorCode: nil))
        #expect(TurnState.outcome(stopped: false, finish: .stop, errorCode: nil, hadContent: true) == .done)
        #expect(TurnState.outcome(stopped: false, finish: .length, errorCode: nil, hadContent: true) == .done)
    }

    @Test func activePhases() {
        #expect(TurnPhase.allCases.filter(\.isActive) == [.queued, .loading, .prefill, .streaming, .toolCall, .finalizing])
    }
}

// MARK: - Status line (NFR-U3, NFR-U4)

@Suite("TurnControllerTests.statusLine") struct StatusLineModelTests {
    @Test func pendingDotThenVerbsAfter2500ms() {
        let m = StatusLineModel(phase: .queued, hasContent: false, modelLoading: false)
        #expect(m.status(elapsed: .zero) == .pendingDot)
        #expect(m.status(elapsed: .milliseconds(2499)) == .pendingDot)
        #expect(m.status(elapsed: .milliseconds(2500)) == .verb(1))
        #expect(m.status(elapsed: .milliseconds(6499)) == .verb(1))
        #expect(m.status(elapsed: .milliseconds(6500)) == .verb(2))
        #expect(m.status(elapsed: .seconds(300)) == .verb(4))
        #expect(m.nextChange(after: .zero) == .milliseconds(2500))
        #expect(m.nextChange(after: .milliseconds(2500)) == .milliseconds(6500))
        #expect(m.nextChange(after: .seconds(300)) == nil)
        #expect(StatusLine.verb(3).copyKey == "status.verb.3")
    }

    @Test func loadingShowsLoadingModelAtOnce() {
        let m = StatusLineModel(phase: .loading, hasContent: false, modelLoading: true)
        #expect(m.status(elapsed: .zero) == .loadingModel)
        #expect(m.status(elapsed: .seconds(10)) == .loadingModel)
        #expect(StatusLine.loadingModel.copyKey == "status.loadingModel")
    }

    @Test func hiddenOnceTextArrivesOrTheTurnEnds() {
        #expect(StatusLineModel(phase: .streaming, hasContent: true, modelLoading: false).status(elapsed: .seconds(5)) == .hidden)
        for p in [TurnPhase.idle, .interrupted, .error, .finalizing] {
            #expect(StatusLineModel(phase: p, hasContent: false, modelLoading: false).status(elapsed: .seconds(5)) == .hidden)
        }
    }

    /// M6.T02 step 7: the whole-document summary shows `status.summarising` with its real n/total/% at once.
    @Test func summarisingShowsRealProgress() {
        let m = StatusLineModel(phase: .prefill, hasContent: false, modelLoading: false,
                                summarising: .init(n: 3, total: 8))
        let line = m.status(elapsed: .milliseconds(100))
        #expect(line.copyKey == "status.summarising")
        #expect(line.copyArgs == ["n": "3", "total": "8", "percent": "37"])
        #expect(m.nextChange(after: .zero) == nil)
        // NFR-C5: a whole document's prefill shows `status.reading` with the real percent (not a verb).
        let r = StatusLineModel(phase: .prefill, hasContent: false, modelLoading: false,
                                reading: .init(file: "doc.pdf", percent: 42)).status(elapsed: .seconds(6))
        #expect(r.copyKey == "status.reading" && r.copyArgs == ["file": "doc.pdf", "percent": "42"])
    }
}

// MARK: - Controller

/// Collects one controller's updates.
final class UpdateLog: Sendable {
    final class Box: Sendable { let items = Mutex<[TurnUpdate]>([]) }
    private let box = Box()
    private let task: Task<Void, Never>

    init(_ controller: TurnController) {
        let box = self.box
        task = Task { for await u in controller.updates { box.items.withLock { $0.append(u) } } }
    }

    deinit { task.cancel() }

    var all: [TurnUpdate] { box.items.withLock { $0 } }

    func text(_ id: String) -> String {
        all.filter { $0.assistantID == id }.reduce(into: "") { s, u in if case .textDelta(let d) = u.kind { s += d } }
    }

    func finished(_ id: String) -> TurnResult? {
        for u in all where u.assistantID == id { if case .finished(let r) = u.kind { return r } }
        return nil
    }

    func phases(_ id: String) -> [TurnPhase] {
        all.filter { $0.assistantID == id }.compactMap { if case .phase(let p) = $0.kind { p } else { nil } }
    }

    /// Waits until `predicate` holds (polling; ≤ `timeout`).
    func wait(_ timeout: Duration = .seconds(10), _ predicate: (UpdateLog) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(self) {
            if ContinuousClock.now > deadline { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitFinished(_ id: String, timeout: Duration = .seconds(10)) async throws -> TurnResult {
        try await wait(timeout) { $0.finished(id) != nil }
        return finished(id)!
    }

    struct TimeoutError: Error {}
}

/// An engine that streams forever and ignores Cancel (the 300 ms grace path; failure mode "MLX finishes the
/// current eval").
final class StubbornEngine: EngineService {
    let cancels = Mutex(0)
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) { cancels.withLock { $0 += 1 } }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { c in
            let t = Task {
                // Not cancellation-aware on purpose: keeps emitting after Cancel and after the consumer left.
                for i in 0..<400 {
                    try? await Task.sleep(for: .milliseconds(10))
                    c.yield(.textDelta(" w\(i)"))
                }
                c.yield(.done(.stop))
                c.finish()
            }
            _ = t
        }
    }
}

struct Harness {
    let database: AppDatabase
    let chatID = StorageID.make()
    let controller: TurnController
    let log: UpdateLog

    init(script: String, engine: (any EngineService)? = nil, policy: StreamFlushPolicy = .standard,
         stopGrace: Duration = .milliseconds(300),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        database = try AppDatabase.inMemory()
        let e = try engine ?? InProcessScriptedEngine(script: EngineScript(text: script))
        controller = TurnController(chatID: chatID, database: database, engine: e, policy: policy, stopGrace: stopGrace,
                                    now: now) { .scripted("inline") }
        log = UpdateLog(controller)
    }

    func message(_ id: String) throws -> MessageRecord? { try MessageRepository(database).message(id) }

    func persistedText(_ id: String) throws -> String {
        try MessageRepository(database).parts(of: id).filter { $0.kind == .text }.map(\.body).joined()
    }

    /// Sends `text` as the first or next message; returns (userID, assistantID).
    func send(_ text: String, parent: String? = nil) async -> (String, String) {
        let u = StorageID.make()
        let a = StorageID.make()
        await controller.start(.send(userID: u, text: text, parentID: parent), assistantID: a)
        return (u, a)
    }
}

func words(_ n: Int, delayMs: Int) -> String {
    (0..<n).map { #"{"t":"textDelta","v":" word\#($0)","delayMs":\#(delayMs)}"# }.joined(separator: "\n")
}

@Suite("TurnControllerTests") struct TurnControllerTests {
    @Test func sendStreamDone() async throws {
        let h = try Harness(script: """
            {"t":"textDelta","v":"Hello!","delayMs":5}
            {"t":"textDelta","v":" How can I help?","delayMs":5}
            """)
        let (u, a) = await h.send("hi")
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done)
        #expect(r.text == "Hello! How can I help?")
        #expect(r.userID == u)
        #expect(r.version == 1 && r.versionCount == 1)
        #expect(try h.message(a)?.status == .done)
        #expect(try h.persistedText(a) == r.text)
        #expect(try h.message(a)?.usage?.completionTokens == 2)
        #expect(h.log.phases(a) == [.queued, .streaming, .finalizing, .idle])
        #expect(await h.controller.phase == .idle)
        // The chat row exists, with the user message then the assistant on its active path.
        #expect(try MessageTree(h.database).visiblePath(h.chatID).map(\.id) == [u, a])
        // Second turn: the prompt contains the first exchange (the script replays its last segment).
        let (_, a2) = await h.send("again", parent: a)
        let r2 = try await h.log.waitFinished(a2)
        #expect(r2.status == .done)
        #expect(try MessageTree(h.database).visiblePath(h.chatID).count == 4)
    }

    @Test func persistsWhileStreaming() async throws {
        // 2,000 words (≥ 20 s): still streaming however loaded the host is when the checks run (Stop ends it).
        let h = try Harness(script: words(2_000, delayMs: 10))
        let (_, a) = await h.send("go")
        try await h.log.wait { $0.text(a).count > 400 }
        try await Task.sleep(for: .milliseconds(600))
        // Within ≤ 500 ms of arrival the text is in the DB, status streaming, and DB and screen are the same stream:
        // one is a prefix of the other. Which one is ahead at the instant of reading is scheduling (the persister and
        // the UI batcher run on their own tasks; under load either can lead), so no order between them is asserted.
        #expect(try h.message(a)?.status == .streaming)
        let persisted = try h.persistedText(a)
        let shown = h.log.text(a)
        #expect(!persisted.isEmpty)
        #expect(shown.hasPrefix(persisted) || persisted.hasPrefix(shown), "shown \(shown.count) / persisted \(persisted.count)")
        await h.controller.stop()
        _ = try await h.log.waitFinished(a)
    }

    @Test func stopKeepsPartialEqualToPersisted() async throws {
        // The grace timer is out of reach (60 s), so finishing proves the cooperative path: the engine's own
        // done(cancelled) ends the turn, never the 300 ms fallback (order, not a wall-clock bar a loaded host stretches).
        let h = try Harness(script: words(600, delayMs: 10), stopGrace: .seconds(60))
        let (_, a) = await h.send("go")
        try await h.log.wait { $0.text(a).count > 200 }
        await h.controller.stop()
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .interrupted)
        #expect(r.errorCode == nil)
        #expect(!r.text.isEmpty)
        #expect(try h.persistedText(a) == r.text)
        #expect(try h.message(a)?.status == .interrupted)
        // The shown text never ran past the kept text (late tokens discarded).
        #expect(h.log.text(a) == r.text)
        #expect(await h.controller.phase == .interrupted)
        #expect(h.log.phases(a).suffix(2) == [.finalizing, .interrupted])
    }

    /// M3.T10 (R-282 AC2): a voice barge-in stores only the spoken prefix, status interrupted; the full text never persists.
    @Test func bargeInStopStoresOnlyTheSpokenSpan() async throws {
        let h = try Harness(script: words(600, delayMs: 10), stopGrace: .seconds(60))
        let (_, a) = await h.send("go")
        try await h.log.wait { $0.text(a).count > 200 }
        let heard = 57
        await h.controller.stop(keepingUTF16: heard)
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .interrupted)
        #expect(r.text.utf16.count == heard)
        #expect(h.log.text(a).hasPrefix(r.text))
        #expect(try h.persistedText(a) == r.text)
        #expect(try h.message(a)?.status == .interrupted)
    }

    @Test func stopFallsBackToTheGraceTimerWhenTheEngineIgnoresCancel() async throws {
        let engine = StubbornEngine()
        let h = try Harness(script: "", engine: engine)
        let (_, a) = await h.send("go")
        try await h.log.wait { $0.text(a).count > 30 }
        let t0 = ContinuousClock.now
        await h.controller.stop()
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        let idle = ContinuousClock.now - t0
        // The engine never ends the turn, so it ended by the grace timer; sleeps only give lower bounds, so the bar is
        // "not before the grace" (an upper bound measured the host's load).
        #expect(idle >= .milliseconds(290), "\(idle)")
        #expect(r.status == .interrupted)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try h.persistedText(a) == r.text)
        #expect(h.log.text(a) == r.text, "late tokens must be discarded")
        #expect(engine.cancels.withLock { $0 } >= 1)
    }

    @Test func stopWhileQueued() async throws {
        let h = try Harness(script: #"{"t":"wait","ms":2000}"# + "\n" + words(5, delayMs: 1))
        let (_, a) = await h.send("go")
        await h.controller.stop()
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .interrupted)
        #expect(r.text.isEmpty)
        #expect(h.log.phases(a) == [.queued, .finalizing, .interrupted])
        #expect(try h.message(a)?.status == .interrupted)
    }

    @Test func stopDuringPrefill() async throws {
        let h = try Harness(script: #"{"t":"prefill","ms":3000,"steps":30}"# + "\n" + words(5, delayMs: 1))
        let (_, a) = await h.send("go")
        try await h.log.wait { $0.phases(a).contains(.prefill) }
        await h.controller.stop()
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .interrupted && r.text.isEmpty)
        #expect(h.log.phases(a) == [.queued, .prefill, .finalizing, .interrupted])
    }

    @Test func stopDuringModelLoad() async throws {
        let h = try Harness(script: #"{"t":"load","ms":3000,"steps":10}"# + "\n" + words(5, delayMs: 1))
        let (_, a) = await h.send("go")
        try await h.log.wait { log in log.all.contains { $0.assistantID == a && $0.kind == .modelLoading(true) } }
        try await h.log.wait { $0.phases(a).contains(.loading) }
        await h.controller.stop()
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .interrupted)
        #expect(h.log.phases(a) == [.queued, .loading, .finalizing, .interrupted])
    }

    @Test func crashMidStreamIsInterruptedWithEngineRestarted() async throws {
        let h = try Harness(script: words(40, delayMs: 2) + "\n" + #"{"t":"crash"}"#)
        let (_, a) = await h.send("go")
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .interrupted)
        #expect(r.errorCode == "engine.restarted")
        #expect(r.text.split(separator: " ").count == 40)
        #expect(try h.persistedText(a) == r.text)
        #expect(try h.message(a)?.errorCode == "engine.restarted")
        #expect(h.log.phases(a) == [.queued, .streaming, .finalizing, .interrupted])
    }

    @Test func engineErrorEventMidStreamIsTheSameNotice() async throws {
        let h = try Harness(script: words(10, delayMs: 2) + "\n" + #"{"t":"error","code":"engine.restarted"}"#)
        let (_, a) = await h.send("go")
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .interrupted && r.errorCode == "engine.restarted")
    }

    struct CrashCase: Sendable, CustomStringConvertible {
        var name: String
        var script: String
        var phases: [TurnPhase]
        var description: String { name }
    }

    static let crashCases: [CrashCase] = [
        CrashCase(name: "queued", script: #"{"t":"crash"}"#, phases: [.queued, .finalizing, .error]),
        CrashCase(name: "loading", script: #"{"t":"load","ms":200,"steps":2}"# + "\n" + #"{"t":"crash"}"#,
                  phases: [.queued, .loading, .prefill, .finalizing, .error]),
        CrashCase(name: "prefill", script: #"{"t":"prefill","ms":100,"steps":2}"# + "\n" + #"{"t":"crash"}"#,
                  phases: [.queued, .prefill, .finalizing, .error]),
        CrashCase(name: "toolCall", script: #"{"t":"toolCallDelta","id":"c1","name":"echo","v":"{"}"# + "\n" + #"{"t":"crash"}"#,
                  phases: [.queued, .toolCall, .finalizing, .error]),
    ]

    /// Crash in each pre-content state → `error` (nothing to keep); during a tool call likewise.
    @Test(arguments: TurnControllerTests.crashCases)
    func crashBeforeContent(_ c: CrashCase) async throws {
        let (name, phases) = (c.name, c.phases)
        let h = try Harness(script: c.script)
        let (_, a) = await h.send("go")
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .error, "\(name)")
        #expect(r.errorCode == "engine.restarted")
        #expect(h.log.phases(a) == phases, "\(name)")
        #expect(try h.message(a)?.status == .error)
    }

    @Test func retryCreatesASiblingVersion() async throws {
        let h = try Harness(script: words(300, delayMs: 5))
        let (u, a) = await h.send("go")
        try await h.log.wait { $0.text(a).count > 50 }
        await h.controller.stop()
        let r1 = try await h.log.waitFinished(a)
        #expect(r1.status == .interrupted)
        let a2 = StorageID.make()
        await h.controller.start(.retry(assistantID: a), assistantID: a2)
        try await h.log.wait { log in log.all.contains { $0.assistantID == a2 && $0.kind == .accepted(version: 2, versionCount: 2, userVersion: 1, userVersionCount: 1) } }
        try await h.log.wait { $0.text(a2).count > 20 }
        await h.controller.stop()
        let r2 = try await h.log.waitFinished(a2)
        #expect(r2.version == 2 && r2.versionCount == 2)
        #expect(r2.userID == u)
        #expect(try MessageTree(h.database).siblings(of: a).map(\.id) == [a, a2])
        #expect(try MessageTree(h.database).visiblePath(h.chatID).map(\.id) == [u, a2])
        // The old version keeps its interrupted partial text.
        #expect(try h.persistedText(a) == r1.text)
    }

    @Test func editPromptCreatesAUserSibling() async throws {
        let h = try Harness(script: words(3, delayMs: 1))
        let (u, a) = await h.send("first")
        _ = try await h.log.waitFinished(a)
        let u2 = StorageID.make()
        let a2 = StorageID.make()
        await h.controller.start(.edit(userID: u, newUserID: u2, text: "second"), assistantID: a2)
        let r = try await h.log.waitFinished(a2)
        #expect(r.userID == u2 && r.userVersion == 2 && r.userVersionCount == 2)
        #expect(try MessageTree(h.database).visiblePath(h.chatID).map(\.id) == [u2, a2])
        let userText = try MessageRepository(h.database).parts(of: u2).map(\.body).joined()
        #expect(userText == "second")
    }

    @Test func sendIsIgnoredWhileATurnRuns() async throws {
        let h = try Harness(script: words(100, delayMs: 10))
        let (_, a) = await h.send("go")
        let (_, b) = await h.send("again", parent: a)
        #expect(try h.message(b) == nil)
        await h.controller.stop()
        _ = try await h.log.waitFinished(a)
    }

    @Test func launchSweepMarksStreamingRowsInterrupted() async throws {
        let h = try Harness(script: words(1, delayMs: 1))
        let chat = try ChatRepository(h.database).create()
        let tree = MessageTree(h.database)
        let user = try tree.append(chatID: chat.id, parentID: nil, role: .user, parts: [.text("q")])
        let streaming = try tree.append(chatID: chat.id, parentID: user.id, role: .assistant, status: .streaming,
                                        parts: [.text("partial")])
        #expect(TurnController.launchSweep(h.database) == [streaming.id])
        #expect(try h.message(streaming.id)?.status == .interrupted)
        #expect(try h.persistedText(streaming.id) == "partial")
        #expect(TurnController.launchSweep(h.database).isEmpty)
    }

    @Test func chatEnvironmentSweepsAtOpenAndMakesControllers() async throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create()
        let u = try MessageTree(db).append(chatID: chat.id, parentID: nil, role: .user, parts: [.text("q")])
        let s = try MessageTree(db).append(chatID: chat.id, parentID: u.id, role: .assistant, status: .streaming)
        let env = ChatEnvironment(
            database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: words(2, delayMs: 1))),
            slot: { .scripted("inline") })
        #expect(env.sweptMessageIDs == [s.id])
        let c = env.controller(chatID: chat.id)
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "next", parentID: s.id), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
    }
}
