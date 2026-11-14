// M4 review P1-2 / P1-3 / P1-5 (R-291, R-285, R-231 incognito): the media queue's files and stores.
//   * P1-2: a job's xfer dir is deleted when it ends blocked / failed / cancelled, a lost job keeps only its inputs,
//     a done job keeps its result until the caller stored it (`discardFiles`), and the launch sweep removes dirs of
//     ended or unknown jobs.
//   * P1-3: an incognito chat (in-memory store) has no row in the persistent database — enqueueing it there fails on
//     the chat foreign key (the bug, confirmed) — so its jobs run in its session's own queue on its store (M5.T14 review
//     P1-1 design: `ephemeral` + `register`, picked by `serving`), with a temp `AntiChat-incognito-*` root; the
//     persistent database gets nothing.
//   * P1-5: Erase's mask is written into the job's dir and moves to the new job on Restart of a lost job.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct MediaJobFilesTests {
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("xfer-files-\(UUID().uuidString)", isDirectory: true)
    }

    /// A job dir with a preview and a result, as the helper would leave it.
    static func populate(_ root: URL, _ job: String) throws {
        let dir = root.appendingPathComponent(job)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("preview-0001.png"))
        try Data([2]).write(to: dir.appendingPathComponent("result.png"))
    }

    static func exists(_ root: URL, _ job: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(job).path) }

    @Test func endedJobsLeaveNoFiles() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        for terminal in ["blocked", "failed", "cancelled", "done"] {
            let id = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
            try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, id) == .running }
            try Self.populate(root, id)
            let event: MediaJobEvent = switch terminal {
            case "blocked": .jobBlocked(job: id)
            case "failed": .jobFailed(job: id, code: "x")
            case "cancelled": .jobCancelled(job: id)
            default: .jobResult(job: id, path: root.appendingPathComponent(id).appendingPathComponent("result.png").path, metadata: [:])
            }
            t.end(id, event)
            _ = await q.finished(id)
            if terminal == "done" {
                #expect(Self.exists(root, id), "kept until the caller stored the result")
                await q.discardFiles(id)
            }
            #expect(!Self.exists(root, id), "\(terminal): xfer dir removed")
        }
    }

    @Test func lostKeepsInputsAndRestartMovesThem() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let mask = Data("mask".utf8)
        let a = try await q.enqueue(chatID: chat, kind: .local, image: MediaJobQueueTests.spec(), maskPNG: mask)
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, a) == .running }
        let maskPath = try #require(t.submitted[0].image.maskImagePath)
        #expect(maskPath.hasPrefix(root.appendingPathComponent(a).path), "the mask lives in the job's dir")
        try Data([1]).write(to: root.appendingPathComponent(a).appendingPathComponent("preview-0001.png"))
        t.send(a, [.engine(.error(AntiChatError(.engineRestarted, detail: "crash")))], finish: true)
        try await MediaJobQueueTests.until("lost") { try await MediaJobQueueTests.state(q, a) == .lost }
        #expect(FileManager.default.contents(atPath: maskPath) == mask, "a lost job keeps its inputs")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(a).appendingPathComponent("preview-0001.png").path))
        let b = try await q.restart(a)
        try await MediaJobQueueTests.until("restart running") { try await MediaJobQueueTests.state(q, b) == .running }
        let newMask = try #require(t.submitted[1].image.maskImagePath)
        #expect(newMask.hasPrefix(root.appendingPathComponent(b).path) && FileManager.default.contents(atPath: newMask) == mask)
        #expect(!Self.exists(root, a), "the old job's dir went with the restart")
    }

    /// The sweep removes only this queue's dirs (its ended jobs). A dir with no row in its database — another queue's
    /// in a shared root (another container, build or test) — survives.
    @Test func launchSweepRemovesOnlyItsOwnDirs() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: root, safety: { nil })
        let a = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(q, a) == .running }
        let b = try await q.enqueue(chatID: chat, image: MediaJobQueueTests.spec())
        try await q.cancel(b)  // queued → cancelled: an ended job of this queue
        try Self.populate(root, a)
        try Self.populate(root, b)
        try Self.populate(root, "foreign-job")
        #expect(await q.sweepFiles() == 1)
        #expect(Self.exists(root, a), "a running job keeps its dir")
        #expect(!Self.exists(root, b), "an ended job's dir goes")
        #expect(Self.exists(root, "foreign-job"), "another queue's dir survives")
    }

    @Test func incognitoJobsStayInTheirStore() async throws {
        let (persistent, _) = try MediaJobQueueTests.setUp()
        let incognito = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try incognito.write { try chat.insert($0) }
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FakeMediaTransport()
        let shared = MediaJobQueue(database: persistent, transport: t, xferRoot: root, safety: { nil })
        // The bug (confirmed): the persistent queue cannot hold an incognito chat's job (chat foreign key).
        await #expect(throws: (any Error).self) { try await shared.enqueue(chatID: chat.id, image: MediaJobQueueTests.spec()) }
        // The fix: the chat's store has its own queue; its rows and files are never in the persistent ones.
        let child = shared.ephemeral(database: incognito, xferRoot: IncognitoTemp.make("xfer-\(UUID().uuidString)"))
        MediaJobQueue.register(child, for: incognito)
        defer { MediaJobQueue.unregister(database: incognito) }
        #expect(child !== shared && MediaJobQueue.serving(incognito, app: shared) === child
                && MediaJobQueue.serving(persistent, app: shared) === shared)
        let id = try await child.enqueue(chatID: chat.id, image: MediaJobQueueTests.spec(), callID: "call-1")
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(child, id) == .running }
        #expect(shared.hasRunning, "the quit prompt sees incognito jobs")
        let out = try #require(t.submitted.last?.image.outputPath)
        #expect(out.contains(IncognitoSession.tempPrefix + "xfer-") && !out.hasPrefix(root.path))
        #expect(try persistent.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_job") } == 0)
        #expect(try incognito.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_job") } == 1)
        let found = try #require(await MediaJobQueue.job(forCall: "call-1"))
        #expect(found.queue === child && found.job == id)
        t.end(id, .jobCancelled(job: id))
        _ = await child.finished(id)
    }
}
