// M4.T04 (R-291 AC1/AC2, R-285 AC5 app leg): the app's durable media job queue against a fake helper transport.
// One job runs at a time with positions; a helper crash or another engine instance turns `running` into `lost`;
// Restart re-enqueues the same spec; a blocked job leaves exactly one record (`child_safety_blocks` += 1), writes
// nothing (the queue never touches image bytes) and contacts nothing but the helper; safety-missing fails the job.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A scripted helper: each submit opens a stream the test drives.
final class FakeMediaTransport: MediaJobTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [String: AsyncStream<EngineBatch>.Continuation] = [:]
    private(set) var submitted: [MediaJobSubmit] = []
    private(set) var cancelled: [UUID] = []
    var instance = "helper-A"

    func engineInstanceID() async throws -> String { lock.withLock { instance } }

    func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch> {
        let (s, c) = AsyncStream<EngineBatch>.makeStream()
        lock.withLock {
            conts[job.job] = c
            submitted.append(job)
        }
        c.yield(EngineBatch(items: [.media(.job(.jobStarted(job: job.job, engineInstanceID: instance)))]))
        return s
    }

    func cancel(_ requestID: UUID) { lock.withLock { cancelled.append(requestID) } }

    var submittedJobs: [String] { lock.withLock { submitted.map(\.job) } }

    func send(_ job: String, _ items: [StreamItem], finish: Bool = false) {
        let c = lock.withLock { conts[job] }
        c?.yield(EngineBatch(items: items))
        if finish { c?.finish() }
    }

    func end(_ job: String, _ event: MediaJobEvent) {
        send(job, [.media(.job(event)), .engine(.done(.stop))], finish: true)
    }
}

/// A helper that takes the job and never answers (no `jobStarted`, no terminal).
final class SilentMediaTransport: MediaJobTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [AsyncStream<EngineBatch>.Continuation] = []
    private(set) var cancelled: [UUID] = []
    func engineInstanceID() async throws -> String { "helper-silent" }
    func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch> {
        let (s, c) = AsyncStream<EngineBatch>.makeStream()
        lock.withLock { conts.append(c) }
        return s
    }
    func cancel(_ requestID: UUID) { lock.withLock { cancelled.append(requestID) } }
    var cancelCount: Int { lock.withLock { cancelled.count } }
}

@Suite(.serialized) struct MediaJobQueueTests {
    /// M4.T16: a job the helper never starts fails with `job.notStarted` within the start bound (the card shows the
    /// error with Retry) instead of staying at 0 % forever; the helper is told to cancel and the next job runs.
    @Test func jobTheHelperNeverStartsFailsWithinTheBound() async throws {
        let (db, chat) = try Self.setUp()
        let t = SilentMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/xfer-test"), safety: { nil },
                              startTimeout: .milliseconds(300))
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        let b = try await q.enqueue(chatID: chat, image: Self.spec())
        let end = await q.finished(a)
        #expect(end.state == .failed && end.errorCode == MediaJobQueue.notStartedCode)
        #expect(t.cancelCount >= 1)
        // The queue is not wedged behind it: the next job is submitted (and fails the same way here).
        let endB = await q.finished(b)
        #expect(endB.errorCode == MediaJobQueue.notStartedCode)
    }

    /// ■ on a job the helper never took: it ends `cancelled` at the bound (not the not-started error).
    @Test func cancelBeforeTheHelperStartsEndsCancelled() async throws {
        let (db, chat) = try Self.setUp()
        let t = SilentMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/xfer-test"), safety: { nil },
                              startTimeout: .milliseconds(300))
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("running") { try await Self.state(q, a) == .running }
        try await q.cancel(a)
        let end = await q.finished(a)
        #expect(end.state == .cancelled && end.errorCode == nil)
    }

    /// A helper that does start the job is never cut off by the start bound, however long the job then takes.
    @Test func startedJobOutlivesTheStartBound() async throws {
        let (db, chat) = try Self.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/xfer-test"), safety: { nil },
                              startTimeout: .milliseconds(100))
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("submitted") { t.submittedJobs.contains(a) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await Self.state(q, a) == .running)
        t.end(a, .jobResult(job: a, path: "/tmp/xfer-test/\(a)/result.png", metadata: [:]))
        #expect(await q.finished(a).state == .done)
    }

    static func setUp() throws -> (AppDatabase, String) {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        return (db, chat.id)
    }

    static func spec() -> ImageRequest {
        ImageRequest(model: ImageModelSet(key: "scripted-image", diffusionModel: "scripted:4:5", llm: "", vae: "", footprintBytes: 0),
                     prompt: "a lighthouse", width: 768, height: 512, seed: 1, outputPath: "")
    }

    /// Polls until `ok`. The cap is a hang guard, not a speed bar: these jobs run on a scripted engine and finish in
    /// milliseconds, but at load 150+ a 5 s cap ran out before the queue's first submit (merge queue 1).
    static func until(_ what: String, _ timeout: Duration = .seconds(90), _ ok: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if try await ok() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out: \(what)")
        // Stop the test here: the caller's next step (e.g. `submitted[0]`) would otherwise crash the test process.
        throw TimedOut(what: what)
    }

    struct TimedOut: Error { let what: String }

    static func state(_ q: MediaJobQueue, _ id: String) async throws -> MediaJobState? { try await q.row(id)?.state }

    @Test func oneAtATimeWithPositions() async throws {
        let (db, chat) = try Self.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/xfer-test"), safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        let b = try await q.enqueue(chatID: chat, image: Self.spec())
        let c = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("a running") { try await Self.state(q, a) == .running }
        #expect(try await q.positions() == [a: 0, b: 1, c: 2])
        #expect(t.submittedJobs == [a], "only one job reaches the helper")
        #expect(q.hasRunning)
        let row = try #require(try await q.row(a))
        #expect(row.engineInstanceID == "helper-A" && row.startedAt != nil)
        #expect(t.submitted[0].previewDir?.hasSuffix("/xfer-test/\(a)") == true)
        #expect(t.submitted[0].image.outputPath == "/tmp/xfer-test/\(a)/result.png")

        t.send(a, [.media(.job(.jobProgress(job: a, step: 2, totalSteps: 4, previewPath: "/tmp/xfer-test/\(a)/preview-0002.png")))])
        try await Self.until("progress") { try await q.row(a)?.progress == 0.5 }
        t.end(a, .jobResult(job: a, path: "/tmp/xfer-test/\(a)/result.png", metadata: [:]))
        try await Self.until("b running") { try await Self.state(q, b) == .running }
        let doneRow = try await q.row(a)
        #expect(doneRow?.state == .done && doneRow?.position == nil && doneRow?.progress == 1)
        #expect(try await q.positions() == [b: 0, c: 1])
        #expect(t.submittedJobs == [a, b])

        try await q.cancel(c)  // waiting: cancelled at once, never submitted
        #expect(try await Self.state(q, c) == .cancelled)
        try await q.cancel(b)  // running: the helper is asked to stop
        #expect(t.cancelled == [t.submitted[1].requestID])
        t.end(b, .jobCancelled(job: b))
        try await Self.until("b cancelled") { try await Self.state(q, b) == .cancelled }
        await q.drain()
        let left = try await q.positions()
        #expect(t.submittedJobs == [a, b] && !q.hasRunning && left.isEmpty)
    }

    /// R-285 AC5 (app leg): blocked → row `blocked`, the counter +1 (its only record), nothing else written.
    @Test func blockedCountsOnceAndRecordsNothingElse() async throws {
        let (db, chat) = try Self.setUp()
        let t = FakeMediaTransport()
        let xfer = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
        let q = MediaJobQueue(database: db, transport: t, xferRoot: xfer, safety: { nil })
        let before = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master") }
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("running") { try await Self.state(q, a) == .running }
        t.end(a, .jobBlocked(job: a))
        try await Self.until("blocked") { try await Self.state(q, a) == .blocked }
        #expect(try db.read { try Int64.fetchOne($0, sql: "SELECT value FROM local_counter WHERE key = 'child_safety_blocks'") } == 1)
        #expect(try await q.row(a)?.errorCode == nil, "no reason is recorded")
        #expect(!FileManager.default.fileExists(atPath: xfer.path), "the queue writes no file")
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master") } == before)
    }

    @Test func safetyMissingFailsTheJob() async throws {
        let (db, chat) = try Self.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/x"), safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("running") { try await Self.state(q, a) == .running }
        #expect(t.submitted[0].safety == nil)
        t.end(a, .safetyMissing(job: a, sizeBytes: 466_000_000))
        try await Self.until("failed") { try await Self.state(q, a) == .failed }
        #expect(try await q.row(a)?.errorCode == MediaJobQueue.safetyMissingCode)
    }

    /// R-291 AC2: a helper crash mid-job (stream ends with engine.restarted, no job terminal) → `lost`; Restart
    /// re-enqueues the same spec as a new job id, the old row stays `lost`.
    @Test func helperCrashMarksLostAndRestartRequeues() async throws {
        let (db, chat) = try Self.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/x"), safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: Self.spec())
        try await Self.until("running") { try await Self.state(q, a) == .running }
        t.send(a, [.engine(.error(AntiChatError(.engineRestarted, detail: "XPC session invalidated")))], finish: true)
        try await Self.until("lost") { try await Self.state(q, a) == .lost }
        t.instance = "helper-B"
        let b = try await q.restart(a)
        #expect(b != a)
        try await Self.until("restart running") { try await Self.state(q, b) == .running }
        #expect(try await Self.state(q, a) == .lost)
        #expect(t.submitted[1].image.prompt == "a lighthouse" && t.submitted[1].image.requestID != t.submitted[0].image.requestID)
        #expect(try await q.row(b)?.engineInstanceID == "helper-B")
    }

    /// Lost detection by engine instance (relaunch / reconnect): rows stamped by another helper launch become `lost`.
    @Test func lostByEngineInstance() async throws {
        let (db, chat) = try Self.setUp()
        try db.write { d in
            try MediaJobRecord(id: "old", chatID: chat, kind: "image", specJSON: "{}", state: .running, engineInstanceID: "helper-0", position: 0).insert(d)
            try MediaJobRecord(id: "same", chatID: chat, kind: "image", specJSON: "{}", state: .running, engineInstanceID: "helper-1", position: 0).insert(d)
        }
        let q = MediaJobQueue(database: db, transport: FakeMediaTransport(), xferRoot: URL(fileURLWithPath: "/tmp/x"), safety: { nil })
        #expect(try await q.reconcile(engineInstanceID: "helper-1") == ["old"])
        #expect(try await Self.state(q, "old") == .lost)
        #expect(try await Self.state(q, "same") == .running)
        // App relaunch: the launch sweep marks every running row lost (RecoveryRepository, M1.T12).
        let r = try RecoveryRepository(db).sweepAfterCrash()
        #expect(r.lostJobs == ["same"])
    }
}
