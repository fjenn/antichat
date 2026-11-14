// M5 review P2-2 / P2-3 and M4 review P2-1 / P2-2: the queue family's one running-job slot and ■ before submit.
//   * a ■ pressed while the job's safety files / helper connection are still awaited ends the job `cancelled` and
//     nothing is ever submitted (image and video jobs);
//   * the app queue and its incognito queues share one slot: a second queue's job stays `queued` (the card shows
//     waiting, never "Preparing… 0 %"), is submitted only when the first job ended, and freed slots go to queues in
//     arrival order (three queues: no barging, nothing submitted twice).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A gate the safety closure waits on (the test opens it): models the MainActor hop / pack refresh before submit.
final class SafetyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasEntered: Bool { lock.withLock { entered } }
    func wait() async {
        await withCheckedContinuation { c in
            let resume = lock.withLock { () -> Bool in
                entered = true
                if open { return true }
                waiters.append(c)
                return false
            }
            if resume { c.resume() }
        }
    }
    func release() {
        let ws = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters = [] }
            return waiters
        }
        for w in ws { w.resume() }
    }
}

@Suite(.serialized) struct MediaJobSlotTests {
    static let root = URL(fileURLWithPath: "/tmp/xfer-slot-test")

    static func video() -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: "waves at dusk", width: 832, height: 480, frames: 33, fps: 24, seed: 3, outputPath: "",
                     scratchDir: "", footprintBytes: 0)
    }

    static func incognito(_ q: MediaJobQueue) throws -> (MediaJobQueue, String) {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-incognito-slot-\(UUID().uuidString)")
        return (q.ephemeral(database: db, xferRoot: root), chat.id)
    }

    // MARK: - ■ before submit

    @Test(arguments: [MediaJobKind.image, .video])
    func cancelWhileAwaitingSafetyIsNeverSubmitted(kind: MediaJobKind) async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let gate = SafetyGate()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { await gate.wait(); return nil })
        let a = kind == .video ? try await q.enqueue(chatID: chat, video: Self.video())
            : try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("safety awaited") { gate.hasEntered }
        try await q.cancel(a)
        gate.release()
        let end = await q.finished(a)
        #expect(end.state == .cancelled && end.errorCode == nil)
        #expect(t.submittedJobs.isEmpty, "a job cancelled before submit never reaches the helper")
        // The queue is free again: the next job is submitted.
        let b = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("next submitted") { t.submittedJobs == [b] }
        t.end(b, .jobCancelled(job: b))
        _ = await q.finished(b)
    }

    // MARK: - one slot across the app queue and its incognito queues

    @Test(arguments: [MediaJobKind.image, .video])
    func incognitoJobWaitsForTheAppQueuesJob(kind: MediaJobKind) async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { nil }, startTimeout: .milliseconds(200))
        let (inc, incChat) = try Self.incognito(q)
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a submitted") { t.submittedJobs == [a] }
        let b = kind == .video ? try await inc.enqueue(chatID: incChat, video: Self.video())
            : try await inc.enqueue(chatID: incChat, image: MediaJobQueueTests.spec())
        // Waiting, not running: no "Preparing… 0 %" card and nothing submitted beside the running job.
        let snap = await inc.snapshot(b)
        #expect(snap?.state == .queued && snap?.position == 1)
        #expect(t.submittedJobs == [a])
        t.end(a, .jobResult(job: a, path: "/tmp/xfer-slot-test/\(a)/result.png", metadata: [:]))
        #expect(await q.finished(a).state == .done)
        try await MediaJobQueueTests.until("b submitted") { t.submittedJobs == [a, b] }
        #expect(try await MediaJobQueueTests.state(inc, b) == .running)
        t.end(b, .jobCancelled(job: b))
        #expect(await inc.finished(b).state == .cancelled)
    }

    @Test func freedSlotGoesToQueuesInArrivalOrder() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { nil })
        let (i1, c1) = try Self.incognito(q)
        let (i2, c2) = try Self.incognito(q)
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a submitted") { t.submittedJobs == [a] }
        let b = try await i1.enqueue(chatID: c1, video: Self.video())
        let c = try await i2.enqueue(chatID: c2, image: MediaJobQueueTests.spec())
        let d = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        #expect(t.submittedJobs == [a])
        t.end(a, .jobCancelled(job: a))
        try await MediaJobQueueTests.until("b next") { t.submittedJobs == [a, b] }
        t.end(b, .jobCancelled(job: b))
        try await MediaJobQueueTests.until("c next") { t.submittedJobs == [a, b, c] }
        t.end(c, .jobCancelled(job: c))
        try await MediaJobQueueTests.until("d next") { t.submittedJobs == [a, b, c, d] }
        t.end(d, .jobCancelled(job: d))
        #expect(await q.finished(d).state == .cancelled)
        #expect(t.submittedJobs == [a, b, c, d], "one at a time, each once")
    }

    @Test func cancelledWaitingQueuePassesTheTurnOn() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { nil })
        let (i1, c1) = try Self.incognito(q)
        let (i2, c2) = try Self.incognito(q)
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a submitted") { t.submittedJobs == [a] }
        let b = try await i1.enqueue(chatID: c1, image: MediaJobQueueTests.spec())
        let c = try await i2.enqueue(chatID: c2, image: MediaJobQueueTests.spec())
        try await i1.cancel(b)  // the incognito session closed: its waiting job goes
        #expect(await i1.finished(b).state == .cancelled)
        t.end(a, .jobCancelled(job: a))
        try await MediaJobQueueTests.until("c next") { t.submittedJobs == [a, c] }
        t.end(c, .jobCancelled(job: c))
        _ = await i2.finished(c)
    }

    // MARK: - session end × shared slot (queue/15: M4 review P1-2 with M5 review P2-3)

    @Test func closedWaitingSessionLeavesTheLine() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { nil })
        let (i1, c1) = try Self.incognito(q)
        let (i2, c2) = try Self.incognito(q)
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a submitted") { t.submittedJobs == [a] }
        let b = try await i1.enqueue(chatID: c1, image: MediaJobQueueTests.spec())
        let c = try await i2.enqueue(chatID: c2, image: MediaJobQueueTests.spec())
        await i1.close()  // the incognito window closed while its job waited for the slot
        #expect(await i1.finished(b).state == .cancelled)
        t.end(a, .jobCancelled(job: a))
        try await MediaJobQueueTests.until("c next") { t.submittedJobs == [a, c] }
        t.end(c, .jobCancelled(job: c))
        _ = await i2.finished(c)
        #expect(t.submittedJobs == [a, c], "the closed session's job was never submitted")
    }

    @Test func closedRunningSessionReleasesTheSlot() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: Self.root, safety: { nil })
        let (inc, incChat) = try Self.incognito(q)
        let b = try await inc.enqueue(chatID: incChat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("b submitted") { t.submittedJobs == [b] }
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        await inc.close()
        #expect(t.submittedJobs == [b], "the app job waits until the closed session's running job ended")
        t.end(b, .jobCancelled(job: b))
        #expect(await inc.finished(b).state == .cancelled)
        try await MediaJobQueueTests.until("a next") { t.submittedJobs == [b, a] }
        await #expect(throws: (any Error).self) { _ = try await inc.enqueue(chatID: incChat, image: MediaJobQueueTests.spec()) }
        t.end(a, .jobCancelled(job: a))
        _ = await q.finished(a)
    }
}
