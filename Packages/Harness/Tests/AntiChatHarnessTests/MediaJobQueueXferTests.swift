// M5.T14 review P1-2 / P1-4 (app side): a job's xfer files (result, poster, previews) never outlive the job — the
// tool's stored copy is the only one, blocked / failed / cancelled / lost jobs leave nothing (a lost job keeps only its
// `input-*` files, M4 review P1-5), and the launch sweep removes the dirs of this queue's ended jobs — never a queued or
// running job's, and never a dir with no row in its database (fix/sweeps: the xfer root is shared by every AntiChat
// process; `MediaJobQueue.sweepFiles`). A result that races the user's cancel ends `cancelled`, and its files go.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct MediaJobQueueXferTests {
    static func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// What the helper leaves in `<xfer>/<job>/` while a video job runs (allowed previews) and after allow (MP4 + poster).
    static func writeJobFiles(_ root: URL, _ job: String, result: Bool) throws -> URL {
        let dir = root.appendingPathComponent(job, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: dir.appendingPathComponent("preview-0003-00.jpg"))
        if result {
            try Data("mp4".utf8).write(to: dir.appendingPathComponent("result.mp4"))
            try Data("jpg".utf8).write(to: dir.appendingPathComponent("result.poster.jpg"))
        }
        return dir
    }

    static func video() -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: "waves", width: 320, height: 192, frames: 17, seed: 1, outputPath: "", scratchDir: "",
                     footprintBytes: 0)
    }

    @Test(arguments: ["blocked", "failed", "cancelled", "lost"])
    func nonResultTerminalsLeaveNoXferFiles(_ end: String) async throws {
        let root = try Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let id = try await q.enqueue(chatID: chat, video: Self.video())
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, id) == .running }
        let dir = try Self.writeJobFiles(root, id, result: false)
        switch end {
        case "blocked": t.end(id, .jobBlocked(job: id))
        case "failed": t.end(id, .jobFailed(job: id, code: "x"))
        case "cancelled": t.end(id, .jobCancelled(job: id))
        default: t.send(id, [.engine(.error(AntiChatError(.engineRestarted, detail: "gone")))], finish: true)
        }
        let done = await q.finished(id)
        #expect(done.state.rawValue == end)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "\(end): xfer/<job> removed")
    }

    @Test func storedResultRemovesTheXferCopy() async throws {
        let root = try Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let id = try await q.enqueue(chatID: chat, video: Self.video())
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, id) == .running }
        let dir = try Self.writeJobFiles(root, id, result: true)
        t.end(id, .jobResult(job: id, path: dir.appendingPathComponent("result.mp4").path, metadata: [:]))
        let done = await q.finished(id)
        #expect(done.state == .done && FileManager.default.fileExists(atPath: dir.path), "kept until the tool stored it")
        await q.resultStored(id, at: "/stored/video.mp4")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(await q.snapshot(id)?.resultPath == "/stored/video.mp4", "observers get the stored copy")
    }

    @Test func aResultThatRacesTheCancelEndsCancelled() async throws {
        let root = try Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let id = try await q.enqueue(chatID: chat, video: Self.video())
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, id) == .running }
        try await q.cancel(id)
        let dir = try Self.writeJobFiles(root, id, result: true)
        t.end(id, .jobResult(job: id, path: dir.appendingPathComponent("result.mp4").path, metadata: [:]))
        let done = await q.finished(id)
        #expect(done.state == .cancelled && done.resultPath == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "the raced result is deleted")
    }

    @Test func launchSweepRemovesOnlyStaleJobDirs() async throws {
        let root = try Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, chat) = try MediaJobQueueTests.setUp()
        let stale = StorageID.make(), queued = StorageID.make(), done = StorageID.make()
        try db.write { d in
            try MediaJobRecord(id: queued, chatID: chat, kind: "video", specJSON: "{}", position: 1).insert(d)
            try MediaJobRecord(id: done, chatID: chat, kind: "video", specJSON: "{}", state: .done).insert(d)
        }
        for id in [stale, queued, done] { _ = try Self.writeJobFiles(root, id, result: true) }
        let other = root.appendingPathComponent("not-a-job", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let upper = root.appendingPathComponent(StorageID.make().uppercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(StorageID.make())
        try Data("x".utf8).write(to: file)
        let q = MediaJobQueue(database: db, transport: FakeMediaTransport(), xferRoot: root, safety: { nil })
        #expect(await q.sweepFiles() == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(done).path), "the ended job's dir goes")
        // `stale` has no row in this database: another process's queue may own it (shared root) — it stays.
        for kept in [root.appendingPathComponent(queued), root.appendingPathComponent(stale), other, upper, file] {
            #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) kept")
        }
        let missing = MediaJobQueue(database: db, transport: FakeMediaTransport(), xferRoot: root.appendingPathComponent("missing"),
                                    safety: { nil })
        #expect(await missing.sweepFiles() == 0)
    }
}
