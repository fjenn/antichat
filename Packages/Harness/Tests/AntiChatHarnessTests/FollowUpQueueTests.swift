// M1.T19 AT-014 harness half: follow-ups queued during a reply keep their order, can be edited and removed, and
// drain one per turn end; Return queues and ⌘Return sends now only while generating. The engine-order leg (two
// queued messages reach a real TurnController in order, the removed one never) runs against the ScriptedEngine.
//   make test-unit FILTER=FollowUpQueueTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("FollowUpQueueTests") struct FollowUpQueueTests {
    @Test func actionDependsOnGeneration() {
        #expect(FollowUpQueue.action(generating: false, sendNow: false) == .send)
        #expect(FollowUpQueue.action(generating: false, sendNow: true) == .send)
        #expect(FollowUpQueue.action(generating: true, sendNow: false) == .enqueue)
        #expect(FollowUpQueue.action(generating: true, sendNow: true) == .sendNow)
    }

    @Test func orderEditRemove() {
        var q = FollowUpQueue()
        let a = q.enqueue("  first  ")
        let b = q.enqueue("second", pastedTexts: ["card"])
        let c = q.enqueue("third")
        let r1 = q.enqueue("   ")
        #expect(r1 == nil)  // nothing to send
        #expect(q.items.map(\.text) == ["first", "second", "third"])
        let r2 = q.edit(b!.id, text: "second, edited")
        #expect(r2)
        #expect(q.items.map(\.text) == ["first", "second, edited", "third"])  // position kept
        let r3 = q.remove(c!.id)
        #expect(r3)
        let r4 = q.remove(c!.id)
        #expect(!r4)
        let r5 = q.edit(a!.id, text: " ")
        #expect(r5)  // an empty edit removes it
        #expect(q.items.map(\.text) == ["second, edited"])
        let r6 = q.popNext()
        #expect(r6?.pastedTexts == ["card"])
        let r7 = q.popNext()
        #expect(r7 == nil)
    }

    /// Two follow-ups during a reply, the middle one removed: the engine receives the first reply's prompt, then
    /// each remaining follow-up in order, and never the removed one.
    @Test func drainedInOrderAfterEachTurn() async throws {
        let script = try EngineScript(text: """
            {"t":"textDelta","v":"Reply one","delayMs":50}
            {"t":"turn"}
            {"t":"textDelta","v":"Reply two"}
            {"t":"turn"}
            {"t":"textDelta","v":"Reply three"}
            """)
        let engine = InProcessScriptedEngine(script: script)
        let db = try AppDatabase.inMemory()
        let chatID = StorageID.make()
        let controller = TurnController(chatID: chatID, database: db, engine: engine, slot: { .scripted("q") })
        var queue = FollowUpQueue()
        var parent: String?
        func run(_ text: String) async {
            let uid = StorageID.make(), aid = StorageID.make()
            await controller.start(.send(userID: uid, text: text, parentID: parent), assistantID: aid)
            parent = aid
        }
        await run("hello")
        // While the first reply streams: two follow-ups, then one of three is removed.
        #expect(await controller.isActive)
        queue.enqueue("follow-up A")
        let removed = queue.enqueue("follow-up B (removed)")!
        queue.enqueue("follow-up C")
        queue.remove(removed.id)
        while await controller.isActive { try await Task.sleep(for: .milliseconds(10)) }
        while let next = queue.popNext() {
            await run(next.text)
            while await controller.isActive { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(engine.requestCount == 3)
        let users = try db.read { d in
            try MessageTree.visiblePath(chatID, db: d).filter { $0.role == .user }
                .map { try MessageRepository.parts(of: $0.id, db: d).map(\.body).joined() }
        }
        #expect(users == ["hello", "follow-up A", "follow-up C"])
    }
}
