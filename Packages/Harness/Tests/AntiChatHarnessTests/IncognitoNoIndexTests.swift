// AT-247 AC1 (M2.T16, R-247): a scripted incognito session of 10 turns enqueues zero title, search-index, embedding
// or memory jobs — BackgroundJobQueue drops each one (counted) — and the persistent `chunk` table is unchanged. The
// control run (a normal chat) shows the same hooks do index.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("IncognitoNoIndexTests", .serialized) struct IncognitoNoIndexTests {
    private func appEnvironment(_ db: AppDatabase) throws -> ChatEnvironment {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: words(4, delayMs: 1)))
        return ChatEnvironment(database: db, engine: engine,
                               tools: ToolRuntime(registry: .m1(scriptedTools: false), permissions: ToolPermissionStore(db)),
                               slot: { .scripted("inline") })
    }

    /// What the app does after a finished turn (ChatSessions.completed + startTitle): every derived-data job kind.
    private func afterTurn(_ env: ChatEnvironment, queue: BackgroundJobQueue, indexer: BackgroundIndexer) async {
        var tasks: [Task<Void, Never>] = []
        for kind in BackgroundJobQueue.Kind.allCases {
            if let t = queue.enqueue(kind, for: env, { _ = try? await indexer.catchUp() }) { tasks.append(t) }
        }
        for t in tasks { await t.value }
    }

    private func chunkCount(_ db: AppDatabase) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk") ?? -1 }
    }

    @Test func incognitoTenTurnsEnqueueNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nidx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try AppDatabase.onDisk(at: root.appendingPathComponent("antichat.sqlite"))
        let app = try appEnvironment(disk)
        let queue = BackgroundJobQueue()
        let indexer = BackgroundIndexer(database: disk)
        let s = try IncognitoSession(app: app, tempRoot: root.appendingPathComponent("tmp"))
        defer { s.discard() }
        let chatID = try s.createChat()
        let controller = s.environment.controller(chatID: chatID)
        let log = UpdateLog(controller)
        var parent: String?
        for i in 0..<10 {
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: "secret turn \(i)", parentID: parent, attachmentIDs: []),
                                   assistantID: a)
            #expect(try await log.waitFinished(a).status == .done)
            parent = a
            await afterTurn(s.environment, queue: queue, indexer: indexer)
        }
        let c = queue.snapshot
        for kind in BackgroundJobQueue.Kind.allCases {
            #expect(c.enqueued[kind, default: 0] == 0, "\(kind) enqueued for incognito")
            #expect(c.droppedIncognito[kind, default: 0] == 10)
        }
        #expect(try chunkCount(disk) == 0)
        #expect(try chunkCount(s.store) == 0)
    }

    @Test func normalChatIsIndexed() async throws {
        let disk = try AppDatabase.inMemory()
        let app = try appEnvironment(disk)
        let queue = BackgroundJobQueue()
        let indexer = BackgroundIndexer(database: disk)
        let chatID = try ChatRepository(disk).create(title: "control").id
        let controller = app.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "public turn", parentID: nil, attachmentIDs: []), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        await afterTurn(app, queue: queue, indexer: indexer)
        #expect(queue.snapshot.enqueued[.index] == 1)
        #expect(try chunkCount(disk) == 2)  // the user message + the reply
    }
}
