// R-291 AC2: an interrupted (`lost`) picture job restarts as the same request (a new job, the card's key attached), its
// result becomes the call's artifact, and the reply's stored activity + tool result carry the new outcome; a reply's
// lost job is found by its message id (a relaunched card that never saw the job).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ImageJobRestartTests {
    @Test func lostJobRestartsAsTheSameRequestAndRewritesTheCall() async throws {
        let f = try ImageEditFlowTests.Fixture()
        let db = f.db, chat = f.chat.id, queue = f.queue
        // The reply that held the call, with its activity and tool result as the turn stored them.
        let message = MessageRecord(chatID: chat, parentID: nil, role: .assistant, status: .done)
        let args = #"{"prompt":"a lighthouse at dusk"}"#
        let activity = ToolActivity(id: "call_1", tool: "create_image", state: .done, argumentsJSON: args,
                                    result: ImageTurnPolicy.Outcome.failed(code: "interrupted").resultJSON)
        try db.write { db in
            try message.insert(db)
            var a = MessagePartRecord(messageID: message.id, idx: 0, kind: .activity, body: activity.partBody)
            try a.insert(db)
            var r = MessagePartRecord(messageID: message.id, idx: 1, kind: .toolResult,
                                      body: #"{"id":"call_1","name":"create_image","result":"{\"error\":\"interrupted\",\"status\":\"failed\"}"}"#,
                                      untrusted: true)
            try r.insert(db)
        }
        // A job of that reply cut off by a helper exit.
        let key = MediaCallKey.make(messageID: message.id, callID: "call_1")
        #expect(MediaCallKey.messageID(of: key) == message.id)
        let req = ImageRequest(model: FakePhoto.set, prompt: "a lighthouse at dusk", width: 96, height: 64, seed: 7, outputPath: "")
        let old = try await queue.enqueue(chatID: chat, messageID: message.id, image: req, callID: key)
        try await MediaJobQueueTests.until("running") { try await MediaJobQueueTests.state(queue, old) == .running }
        f.transport.send(old, [.engine(.error(AntiChatError(.engineRestarted, detail: "helper exited")))], finish: true)
        try await MediaJobQueueTests.until("lost") { try await MediaJobQueueTests.state(queue, old) == .lost }
        #expect(try await queue.lostJob(messageID: message.id) == old, "found by the reply after a relaunch")

        let run = Task {
            await ImageTools.restartInterrupted(job: old, queue: queue, activity: activity, messageID: message.id, callKey: key)
        }
        try await MediaJobQueueTests.until("resubmitted") { f.transport.submittedJobs.count == 2 }
        let sub = f.transport.submitted[1]
        #expect(sub.job != old && sub.image.prompt == "a lighthouse at dusk" && sub.image.seed == 7, "the same request, a new job")
        #expect(try await queue.job(forCall: key) == sub.job, "the card's key follows the new job")
        let out = f.dir.appendingPathComponent("restarted.png")
        try ImageEditFlowTests.png(96, 64, gray: 0.4).write(to: out)
        f.transport.end(sub.job, .jobResult(job: sub.job, path: out.path, metadata: [:]))
        let outcome = await run.value
        guard case .done(let imageID, _, _, let path?) = outcome else { Issue.record("not done: \(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try f.versions(imageID).count == 1, "stored as the call's artifact")
        #expect(try await MediaJobQueueTests.state(queue, old) == .lost, "the old row stays lost")
        // The reply now carries the new outcome (the reloaded chat shows the picture).
        let parts = try db.read { db in try MessageRepository.parts(of: message.id, db: db) }
        let stored = try #require(parts.first { $0.kind == .activity }.flatMap { ToolActivity(partBody: $0.body) })
        #expect(stored.result.flatMap(ImageTurnPolicy.Outcome.parse) == outcome)
        let toolResult = try #require(parts.first { $0.kind == .toolResult }?.body)
        #expect(toolResult.contains(imageID) && !toolResult.contains("interrupted"))
    }

    /// M9 review H2: an engine that reuses `call_1` in every step (MLXAdapter) — Restart of the second step's call
    /// rewrites that step's tool result only; the other steps' results stay as the turn stored them.
    @Test func restartRewritesOnlyItsOwnStepWhenTheCallIDRepeats() async throws {
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{\\"text\\":\\"step {{n}}\\"}","delayMs":1}
            """
        let h = try ToolLoopHarness(script: script, tier: .t0)
        let (_, a) = await h.send()
        _ = try await h.log.waitFinished(a, timeout: .seconds(20))
        let keys = try h.activities(a).filter { $0.kind == .tool }.map(\.id)
        #expect(keys == ["call_1", "call_1#2", "call_1#3"])
        let before = try h.parts(a, .toolResult).map(\.body)
        #expect(before.count == 3 && before.allSatisfy { $0.contains(#""id":"call_1""#) })
        #expect(before.map { $0.contains(#""activity":"call_1#2""#) } == [false, true, false], "each result names its activity")

        let new = ImageTurnPolicy.Outcome.done(imageID: "img-restarted", width: 8, height: 8, path: nil).resultJSON
        try ToolActivityParts.rewrite(activityID: "call_1#2", messageID: a, result: new, in: h.database)
        let after = try h.parts(a, .toolResult).map(\.body)
        #expect(after[0] == before[0] && after[2] == before[2], "the other steps' results are untouched")
        #expect(after[1] != before[1] && after[1].contains("img-restarted"))
        let acts = try h.activities(a).filter { $0.kind == .tool }
        #expect(acts.filter { $0.result == new }.map(\.id) == ["call_1#2"])
    }

    /// Results stored before the activity key was recorded: the n-th result with the call id belongs to `call_1#n`.
    @Test func legacyResultsAreMatchedByStepOrder() {
        func result(_ id: String, _ text: String) -> MessagePartRecord {
            MessagePartRecord(messageID: "m", idx: 0, kind: .toolResult,
                              body: #"{"id":"\#(id)","name":"create_image","result":"\#(text)"}"#, untrusted: true)
        }
        let parts = [result("call_1", "a"), result("call_2", "b"), result("call_1", "c"), result("call_1", "d")]
        #expect(ToolActivityParts.resultIndex(activityID: "call_1", in: parts) == 0)
        #expect(ToolActivityParts.resultIndex(activityID: "call_1#2", in: parts) == 2)
        #expect(ToolActivityParts.resultIndex(activityID: "call_1#3", in: parts) == 3)
        #expect(ToolActivityParts.resultIndex(activityID: "call_1#4", in: parts) == nil)
        #expect(ToolActivityParts.resultIndex(activityID: "call_2", in: parts) == 1)
    }
}
