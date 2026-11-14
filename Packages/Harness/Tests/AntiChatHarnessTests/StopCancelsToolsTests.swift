// M9 review H3: Stop cancels the turn's running tool calls. A stopped turn's picture job is cancelled (the helper is told
// to stop, and a result that races the cancel is not saved); an open video plan card resolves as Cancel and writes no job.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct StopCancelsToolsTests {
    struct Env {
        let db: AppDatabase
        let chatID: String
        let transport = FakeMediaTransport()
        let queue: MediaJobQueue
        let dir: URL
        let controller: TurnController
        let log: UpdateLog

        init(script: String, tools: (MediaJobQueue) -> [RegisteredTool]) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("stop-tools-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            db = try AppDatabase.inMemory()
            FileOutTools.Stores.shared.install(ArtifactStore(database: db, mediaRoot: dir.appendingPathComponent("Media"), incognito: false),
                                               for: db)  // never the dev container
            chatID = try ChatRepository(db).create().id
            queue = MediaJobQueue(database: db, transport: transport, xferRoot: dir.appendingPathComponent("xfer"), safety: { nil })
            let registry = ToolRegistry(tools(queue))
            let runtime = ToolLoopHarness.runtime(registry: registry, database: db, tier: .t3, selection: .off)
            controller = TurnController(chatID: chatID, database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                        tools: runtime) { .scripted("inline") }
            log = UpdateLog(controller)
        }

        func send(_ text: String) async -> String {
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
            return a
        }

        var artifacts: Int { (try? db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact") }) ?? -1 }

        func close() { try? FileManager.default.removeItem(at: dir) }
    }

    static func script(_ tool: String, _ args: String) -> String {
        """
        {"t":"toolCallDone","id":"call_1","name":"\(tool)","args":"\(args)","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Here it is.","delayMs":1}
        """
    }

    @Test func stopCancelsTheRunningPictureJobAndSavesNothing() async throws {
        let e = try Env(script: Self.script("create_image", #"{\"prompt\":\"a lighthouse at dusk\"}"#)) { q in
            ImageTools(queue: q, photo: FakePhoto()).tools()
        }
        defer { e.close() }
        let a = await e.send("draw a lighthouse")
        try await MediaJobQueueTests.until("submitted", .seconds(20)) { !e.transport.submittedJobs.isEmpty }
        let sub = try #require(e.transport.submitted.first)
        await e.controller.stop()
        let r = try await e.log.waitFinished(a)
        #expect(r.status != .done)
        try await MediaJobQueueTests.until("the helper is told to stop", .seconds(10)) { e.transport.cancelled.contains(sub.requestID) }
        // A result that raced the cancel: the stopped turn stores nothing.
        let out = e.dir.appendingPathComponent("\(sub.job).png")
        try ImageEditFlowTests.png(96, 64, gray: 0.4).write(to: out)
        e.transport.end(sub.job, .jobResult(job: sub.job, path: out.path, metadata: [:]))
        try await MediaJobQueueTests.until("job ended", .seconds(10)) {
            let s = try await MediaJobQueueTests.state(e.queue, sub.job)
            return s != .queued && s != .running
        }
        try await Task.sleep(for: .milliseconds(300))  // the cancelled call's own end
        #expect(e.artifacts == 0, "no picture saved for a stopped turn")
        #expect(try e.db.read { db in try String.fetchAll(db, sql: "SELECT body FROM message_part WHERE kind = 'text'") }
            .allSatisfy { !$0.contains("Here it is.") }, "no step after Stop")
    }

    @Test func stopResolvesAnOpenVideoPlanCardAsCancelled() async throws {
        let broker = VideoPlanBroker()
        let models = FakeVideoModels()
        let e = try Env(script: Self.script("create_video", #"{\"prompt\":\"waves rolling onto a beach\"}"#)) { q in
            VideoTools(queue: q, video: models, broker: broker).tools()
        }
        defer { e.close() }
        let a = await e.send("make a video of waves")
        let key = MediaCallKey.make(messageID: a, callID: "call_1")
        try await MediaJobQueueTests.until("plan card open", .seconds(20)) { await broker.request(forCall: key) != nil }
        await e.controller.stop()
        let r = try await e.log.waitFinished(a)
        #expect(r.status != .done)
        try await MediaJobQueueTests.until("card cancelled", .seconds(10)) { await broker.answer(forCall: key) == .cancel }
        #expect(await broker.request(forCall: key) == nil, "the card no longer waits")
        try await Task.sleep(for: .milliseconds(200))
        #expect(e.transport.submittedJobs.isEmpty && models.requestCount == 0, "no job written")
        #expect(e.artifacts == 0)
    }
}
