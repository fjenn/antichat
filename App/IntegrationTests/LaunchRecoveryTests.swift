// M1.T12 AT-208 legs (2, data half) and (4): a database left behind by a crash (a reply `streaming`, a media job
// `running`, a download `downloading`) is swept when the app opens it (`LaunchRecovery.openDatabase`, the launch
// entry point): reply → `interrupted` with its partial text kept, job → `lost` (UI: "Interrupted" + [Retry]),
// download → `queued` (the M2 coordinator resumes it). The sweep is idempotent.
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Foundation
import GRDB
import XCTest

final class LaunchRecoveryTests: XCTestCase {
    func testSweepAfterCrash() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let options = LaunchOptions.parse(["-ANTICHAT_DEV_CONTAINER", container.path])

        // The crashed session: written, then the database is simply dropped (no clean shutdown path runs).
        var ids: (chat: String, user: String, reply: String, done: String, job: String, doneJob: String, dl: String, dlDone: String)
        do {
            let db = try AppDatabase.openDefault(options: options)
            let chat = try ChatRepository(db).create(title: "crash")
            let tree = MessageTree(db)
            let user = try tree.append(chatID: chat.id, parentID: nil, role: .user, parts: [PartContent(kind: .text, body: "hi")])
            let reply = try tree.append(chatID: chat.id, parentID: user.id, role: .assistant, status: .streaming,
                                        parts: [PartContent(kind: .text, body: "Partial ans")])
            let other = try ChatRepository(db).create(title: "fine")
            let ou = try tree.append(chatID: other.id, parentID: nil, role: .user, parts: [PartContent(kind: .text, body: "q")])
            let done = try tree.append(chatID: other.id, parentID: ou.id, role: .assistant, status: .done,
                                       parts: [PartContent(kind: .text, body: "complete")])
            let job = MediaJobRecord(chatID: chat.id, kind: "image", specJSON: "{}", state: .running, progress: 0.4, startedAt: Date())
            let doneJob = MediaJobRecord(chatID: chat.id, kind: "image", specJSON: "{}", state: .done, progress: 1)
            let dl = DownloadRecord(fileSHA256: String(repeating: "a", count: 64), url: "https://huggingface.co/x", bytesDone: 1 << 20,
                                    bytesTotal: 1 << 30, state: "downloading", chunkMap: "{\"done\":[0]}")
            let dlDone = DownloadRecord(fileSHA256: String(repeating: "b", count: 64), url: "https://huggingface.co/y", state: "done")
            try db.write { d in
                try job.insert(d)
                try doneJob.insert(d)
                try dl.insert(d)
                try dlDone.insert(d)
            }
            ids = (chat.id, user.id, reply.id, done.id, job.id, doneJob.id, dl.id, dlDone.id)
        }

        // Relaunch.
        let (db, report) = try LaunchRecovery.openDatabase(options: options)
        XCTAssertEqual(report.interruptedMessages, [ids.reply])
        XCTAssertEqual(report.lostJobs, [ids.job])
        XCTAssertEqual(report.requeuedDownloads, [ids.dl])
        let messages = MessageRepository(db)
        XCTAssertEqual(try messages.message(ids.reply)?.status, .interrupted)
        XCTAssertEqual(try messages.parts(of: ids.reply).first?.body, "Partial ans", "the partial reply is kept")
        XCTAssertEqual(try messages.message(ids.done)?.status, .done)
        XCTAssertEqual(try messages.message(ids.user)?.status, .done)
        try db.read { d in
            XCTAssertEqual(try MediaJobRecord.fetchOne(d, key: ids.job)?.state, .lost)
            XCTAssertNotNil(try MediaJobRecord.fetchOne(d, key: ids.job)?.finishedAt)
            XCTAssertEqual(try MediaJobRecord.fetchOne(d, key: ids.doneJob)?.state, .done)
            let dl = try XCTUnwrap(try DownloadRecord.fetchOne(d, key: ids.dl))
            XCTAssertEqual(dl.state, "queued")
            XCTAssertEqual(dl.bytesDone, 1 << 20, "resume point kept")
            XCTAssertEqual(dl.chunkMap, "{\"done\":[0]}")
            XCTAssertEqual(try DownloadRecord.fetchOne(d, key: ids.dlDone)?.state, "done")
            XCTAssertEqual(try String.fetchOne(d, sql: "PRAGMA integrity_check"), "ok")
        }
        // The UI copy for the lost job and the interrupted reply exist (copy-deck §2/§3, M1 ErrorInline + Retry).
        XCTAssertEqual(AntiChatError(.engineRestarted).recovery, [.retry])

        // Idempotent: a second launch changes nothing.
        XCTAssertTrue(try LaunchRecovery.run(on: db).isEmpty)
        EngineTestSupport.evidence("AT-208-launch-recovery", [
            "interrupted": report.interruptedMessages, "lost": report.lostJobs, "requeued": report.requeuedDownloads,
        ])
    }
}
