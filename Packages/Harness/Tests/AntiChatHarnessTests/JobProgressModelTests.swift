// M4.T08 step 1 (R-031 AC1, IS-8, NFR-P3): the card's % is floor(100 × completed / total), never decreases, and is
// 100 only once the result arrived (the last step without a result reads 99). Plus the queue side of the card: one
// stream per observer (two cards never take each other's updates) and call → job lookup.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct JobProgressModelTests {
    @Test func realPercentMonotonicAndHundredOnlyWithResult() {
        var m = JobProgressModel()
        var seen: [Int] = []
        for (step, total) in [(0, 8), (1, 8), (2, 8), (3, 8), (2, 8), (5, 8), (1, 4), (8, 8)] {
            m.observe(progress: Double(step) / Double(total))
            seen.append(m.percent)
        }
        #expect(seen == [0, 12, 25, 37, 37, 62, 62, 99])
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        m.finished()
        #expect(m.percent == 100)
        m.observe(progress: 0.1)
        #expect(m.percent == 100)
        var n = JobProgressModel()
        n.observe(progress: .nan)
        #expect(n.percent == 0)
    }

    @Test func everyObserverGetsEveryUpdateAndCallsFindTheirJob() async throws {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: FileManager.default.temporaryDirectory, safety: { nil })
        let a = await q.subscribe(), b = await q.subscribe()
        let req = ImageRequest(model: ImageModelSet(key: "k", diffusionModel: "d", llm: "l", vae: "v", footprintBytes: 1),
                               prompt: "x", width: 64, height: 64, seed: 1, outputPath: "")
        let id = try await q.enqueue(chatID: chat.id, image: req, callID: "call_7")
        let found = await q.job(forCall: "call_7"), other = await q.job(forCall: "other")
        #expect(found == id && other == nil)
        try await MediaJobQueueTests.until("submitted") { t.submittedJobs.count == 1 }
        t.end(id, .jobCancelled(job: id))
        func terminal(_ s: AsyncStream<MediaJobQueue.Update>) async -> MediaJobState? {
            for await u in s where u.job == id && u.state == .cancelled { return u.state }
            return nil
        }
        #expect(await terminal(a) == .cancelled)
        #expect(await terminal(b) == .cancelled)
        #expect(await q.snapshot(id)?.state == .cancelled)
    }
}
