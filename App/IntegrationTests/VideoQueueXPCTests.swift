// M5.T10 (R-040 AC1, R-043 AC2; D-006) through the real XPC helper: a video job queued in the app's MediaJobQueue
// (kind `video`, `MediaJobSubmit.video`) runs in the helper's MediaJobRunner under the queue's job id with the
// ScriptedVideoEngine (no runtime, no model). No detector manifest is passed, so the gate fails closed on the final
// frames: the row ends `failed`/`safety.missing` after every scripted step ran, and nothing is written to the job's
// xfer dir (no MP4, no poster). Same queue, same runner, same gate as an image job (MediaJobQueueXPCTests).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Foundation
import XCTest

final class VideoQueueXPCTests: XCTestCase {
    func testVideoJobRunsThroughTheQueueAndTheHelperGate() async throws {
        let client = EngineClient(appBuild: "it-video-queue")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let xfer = FileManager.default.temporaryDirectory.appendingPathComponent("xpc-video-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: xfer) }
        let q = MediaJobQueue(database: db, transport: client, xferRoot: xfer, safety: { nil })
        let script = ScriptedVideoScript(steps: 3, delayMs: 50, frames: 17, fps: 8, previewFrames: 0)
        let req = VideoRequest(mode: .t2v, prompt: "a lighthouse on a cliff", width: 64, height: 32, frames: 17, fps: 8, seed: 1,
                               outputPath: "", scratchDir: "", footprintBytes: 0, generator: script.generator)
        let id = try await q.enqueue(chatID: chat.id, video: req)
        let end = await q.finished(id)
        XCTAssertEqual(end.state, .failed)
        XCTAssertEqual(end.errorCode, MediaJobQueue.safetyMissingCode, "no detectors: the gate fails closed on the clip")
        let row = try await q.row(id)
        XCTAssertEqual(row?.kind, "video")
        XCTAssertNotNil(row?.engineInstanceID)
        let files = (FileManager.default.enumerator(atPath: xfer.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".mp4") || $0.hasSuffix(".jpg") }, "nothing unchecked written: \(files)")
        EngineTestSupport.evidence("video-queue-xpc", ["state": end.state.rawValue, "error": end.errorCode ?? "", "files": files.count])
    }
}
