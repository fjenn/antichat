// M4 review fixes on the app side of the media queue:
//   * P1-2: an incognito session's end closes its queue (every job cancelled, no new one, its root removed once the
//     running job ended, even when a late result raced the cancel); a cancelled wait (a stopped turn) cancels its job;
//     a closed store gets no fresh media root; a failed artifact insert leaves no file behind.
//   * P2-3: rows still `queued` at launch are settled `lost` (Retry), never run ahead of new work.
//   * P2-6: the launch sweep removes a lost job's dir (inputs included); a restart without its input refuses.
//   * P2-5: Erase / Remove background with missing detectors reports `safetyMissing` with the repair size.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct MediaJobSessionEndTests {
    @Test func closeCancelsEverythingAndRemovesTheRootAfterTheRunningJobEnds() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let root = MediaJobFilesTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a running") { try await MediaJobQueueTests.state(q, a) == .running }
        let b = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try MediaJobFilesTests.populate(root, a)
        await q.close()
        #expect(try await MediaJobQueueTests.state(q, b) == .cancelled, "the waiting job is cancelled at once")
        #expect(t.cancelled.count == 1, "the helper is told to stop the running job")
        #expect(FileManager.default.fileExists(atPath: root.path), "the running job still owns its dir")
        await #expect(throws: (any Error).self) { _ = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec()) }
        // A result that raced the cancel: the job ends cancelled and nothing of the session stays.
        t.end(a, .jobResult(job: a, path: root.appendingPathComponent(a).appendingPathComponent("result.png").path, metadata: [:]))
        #expect(await q.finished(a).state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: root.path), "the session's xfer root is gone")
        #expect(t.submittedJobs == [a], "no further job starts on a closed queue")
    }

    @Test func closeWithNothingRunningRemovesTheRootAtOnce() async throws {
        let (db, _) = try MediaJobQueueTests.setUp()
        let root = MediaJobFilesTests.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let q = MediaJobQueue(database: db, transport: FakeMediaTransport(), xferRoot: root, safety: { nil })
        await q.close()
        #expect(await q.isClosed)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cancellingTheWaitingTaskCancelsItsJob() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: MediaJobFilesTests.root(), safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("a running") { try await MediaJobQueueTests.state(q, a) == .running }
        let waiter = Task { await q.finished(a) }
        waiter.cancel()  // the turn was stopped
        try await MediaJobQueueTests.until("helper told to cancel") { t.cancelled.count == 1 }
        t.end(a, .jobCancelled(job: a))
        #expect(await waiter.value.state == .cancelled)
    }

    @Test func aClosedStoreGetsNoNewMediaRootAndAFailedInsertLeavesNoFile() async throws {
        let db = try AppDatabase.inMemory()
        let stores = FileOutTools.Stores()
        #expect(stores.openStore(for: db) != nil)
        stores.close(db)
        #expect(stores.openStore(for: db) == nil, "a late result of a closed session is never given a fresh temp dir")
        // ArtifactStore: the chat row is gone (FK) → the insert fails → the PNG it wrote first is removed again.
        let root = MediaJobFilesTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(database: try AppDatabase.inMemory(), mediaRoot: root, incognito: true)
        #expect(throws: (any Error).self) {
            _ = try store.save(chatID: "no-such-chat", kind: "image", filename: "image.png", data: Data([1, 2, 3]), specJSON: nil, messageID: nil)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "nothing stays on disk: \(left)")
    }

    @Test func queuedRowsAtLaunchAreSettledLostAndNeverRunAheadOfNewWork() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        try db.write { d in
            try MediaJobRecord(id: "orphan-1", chatID: chat, kind: "image", specJSON: "{}", state: .queued, createdAt: Date(timeIntervalSince1970: 1), position: 1).insert(d)
            try MediaJobRecord(id: "orphan-2", chatID: chat, kind: "image", specJSON: "{}", state: .queued, createdAt: Date(timeIntervalSince1970: 2), position: 2).insert(d)
        }
        let r = try RecoveryRepository(db).sweepAfterCrash()
        #expect(r.lostJobs == ["orphan-1", "orphan-2"])
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: MediaJobFilesTests.root(), safety: { nil })
        #expect(try await MediaJobQueueTests.state(q, "orphan-1") == .lost)
        #expect(try await q.row("orphan-2")?.position == nil)
        let fresh = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("fresh running") { try await MediaJobQueueTests.state(q, fresh) == .running }
        #expect(t.submittedJobs == [fresh], "the user's new job runs first and alone")
        #expect(try await q.positions() == [fresh: 0])
    }

    @Test func launchSweepRemovesALostJobsInputsAndRestartThenRefuses() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let root = MediaJobFilesTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let a = try await q.enqueue(chatID: chat, kind: .local, image: MediaJobQueueTests.spec(), maskPNG: Data("mask".utf8))
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, a) == .running }
        t.send(a, [.engine(.error(AntiChatError(.engineRestarted, detail: "crash")))], finish: true)
        try await MediaJobQueueTests.until("lost") { try await MediaJobQueueTests.state(q, a) == .lost }
        #expect(MediaJobFilesTests.exists(root, a), "within this run the inputs stay for a restart")
        // Next launch: nothing restarts a job of an earlier run, so its dir (the brush mask too) goes.
        let next = MediaJobQueue(database: db, transport: FakeMediaTransport(), xferRoot: root, safety: { nil })
        #expect(await next.sweepFiles() == 1)
        #expect(!MediaJobFilesTests.exists(root, a))
        await #expect(throws: (any Error).self) { _ = try await next.restart(a) }
    }

    @Test func editorActionsReportMissingDetectorsWithTheRepairSize() async throws {
        let f = try ImageEditFlowTests.Fixture()
        let art = try await ImageEditorActionsTests.picture(f)
        let db = f.db, chat = f.chat.id
        let (o, _) = try await ImageEditorActionsTests.runAction(f, photo: ImageEditorActionsTests.Photo(),
                                                                 { await $0.removeBackground(sourceID: art, chatID: chat, database: db) }) {
            .safetyMissing(job: $0.job, sizeBytes: 1)
        }
        #expect(o == .safetyMissing(sizeBytes: 1), "the viewer shows the repair card, not a generic error (R-285 AC6)")
    }
}
