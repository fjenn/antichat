// M8.T02 AT-243 (R-243 AC1/AC2): a 5-turn ScriptedEngine chat whose turn 2 calls `memory save`. The stable prefix
// hash is identical for turns 1–5, the stored `memory_snapshot_hash` survives a reopen of the database, turns 3–5
// carry the volatile line with the new fact and turns 1–2 do not; a > 2,000-char memory set gives a block ≤ 2,000
// chars holding the items nearest the first message. Also: no memory tool and no snapshot when the chat is off.
//   make test-unit FILTER=MemorySnapshotTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

struct AxisEmbedder: Embedder {
    /// Texts mentioning `word` point along axis 0, everything else along a per-text axis.
    let word: String
    func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]] {
        texts.map { t in
            var v = [Float](repeating: 0, count: VecLoader.dimensions)
            if t.lowercased().contains(word) { v[0] = 1 } else { v[1 + abs(t.hashValue) % 500] = 1 }
            return v
        }
    }
    func rerank(query: String, documents: [String]) async throws -> [Float]? { nil }
}

@Suite(.serialized) struct MemorySnapshotTests {
    static func setup(_ dir: URL, script: String, policy: MemoryPolicy = MemoryPolicy())
        throws -> (AppDatabase, TurnController, UpdateLog, String, MemoryRuntime)
    {
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let memory = MemoryRuntime(database: db, policy: { policy })
        let registry = ToolRegistry([memory.tool()])
        let runtime = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(.t1), selection: .off,
                                  router: nil, tier: { .t1 })
        let chatID = StorageID.make()
        let controller = TurnController(chatID: chatID, database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                        tools: runtime, memory: memory) { .scripted("inline") }
        return (db, controller, UpdateLog(controller), chatID, memory)
    }

    static let save = #"{"t":"toolCallDone","id":"m1","name":"memory","args":"{\"action\":\"save\",\"topic\":\"Food\",\"key\":\"diet\",\"value\":\"vegetarian\"}","delayMs":1}"#

    @Test func snapshotIsFrozenAndWritesRideTheVolatileLine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memsnap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var chatID = ""
        var hashes: [String] = []
        var lines: [Bool] = []
        do {
            let script = [#"{"t":"textDelta","v":"one","delayMs":1}"#, Self.save, #"{"t":"textDelta","v":"saved","delayMs":1}"#,
                          #"{"t":"textDelta","v":"three","delayMs":1}"#, #"{"t":"textDelta","v":"four","delayMs":1}"#,
                          #"{"t":"textDelta","v":"five","delayMs":1}"#].joined(separator: "\n{\"t\":\"turn\"}\n")
            let (db, c, log, id, memory) = try Self.setup(dir, script: script)
            chatID = id
            // Something already known before the chat starts.
            try memory.store.insert(topic: "Work", key: "job", text: "Nurse", origin: .user)
            var parent: String?
            for turn in 1...5 {
                let u = StorageID.make(), a = StorageID.make()
                await c.start(.send(userID: u, text: "turn \(turn)", parentID: parent), assistantID: a)
                _ = try await log.waitFinished(a, timeout: .seconds(30))
                parent = a
                let prompt = await c.lastPrompt, request = await c.lastRequest
                hashes.append(try #require(prompt?.stableSHA256))
                lines.append(request?.turnContext?.contains("Memory written in this chat: diet: vegetarian") == true)
                #expect(prompt?.stablePrefix.contains("- [Work] Nurse") == true, "turn \(turn): snapshot block")
                #expect(prompt?.stablePrefix.contains("vegetarian") == false, "turn \(turn): new fact in the stable prefix")
            }
            #expect(try memory.store.active().count == 2)
            let reads = try db.read { try MessageRecord.fetchOne($0, key: parent!)?.provenance?.memoryReads }
            #expect(reads?.count == 1)
            try (db.writer as? DatabasePool)?.close()
        }
        #expect(Set(hashes).count == 1, "stable prefix changed: \(hashes)")
        #expect(lines == [false, false, true, true, true], "\(lines)")
        // Relaunch: the stored snapshot (and its hash) is reused verbatim.
        let reopened = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let builder = MemorySnapshotBuilder(store: MemoryStore(database: reopened), embedder: nil)
        let before = try builder.storedHash(chatID: chatID)
        let again = try await builder.snapshot(chatID: chatID, firstUserMessage: "other", usable: true)
        #expect(try builder.storedHash(chatID: chatID) == before && again.block.contains("Nurse") && !again.block.contains("vegetarian"))
        print("AT-243 hashes turns 1-5: \(hashes.map { String($0.prefix(12)) })")
    }

    @Test func largeMemoryKeepsTheNearestWithinTheCap() async throws {
        let db = try AppDatabase.inMemory()
        try db.write { try $0.execute(sql: "INSERT INTO chat (id, created_at, updated_at) VALUES ('c', 0, 0)") }
        let store = MemoryStore(database: db)
        let embedder = AxisEmbedder(word: "garden")
        for i in 0..<40 {
            let text = (i % 10 == 0 ? "Grows tomatoes in the garden bed \(i) " : "Unrelated long fact number \(i) ") + String(repeating: "x", count: 60)
            try store.insert(topic: "T\(i % 4)", key: "k\(i)", text: text, origin: .user, vector: try await embedder.embed([text], kind: .document)[0])
        }
        let snap = try await MemorySnapshotBuilder(store: store, embedder: embedder)
            .snapshot(chatID: "c", firstUserMessage: "What should I plant in my garden?", usable: true)
        #expect(snap.block.count <= MemorySnapshotBuilder.maxChars && snap.block.count > 1_500)
        #expect(snap.block.components(separatedBy: "garden bed").count - 1 == 4, "all 4 nearest items kept")
    }

    @Test func memoryOffChatGetsNoToolAndNoSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, c, log, chatID, memory) = try Self.setup(dir, script: #"{"t":"textDelta","v":"ok","delayMs":1}"#)
        try memory.store.insert(topic: "Work", key: "job", text: "Nurse", origin: .user)
        try db.write { try ChatRecord(id: chatID, mode: .normal, memoryEnabled: false).insert($0) }
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "hi", parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a, timeout: .seconds(30))
        let request = await c.lastRequest, prompt = await c.lastPrompt
        #expect(request?.tools.contains { $0.name == MemoryTool.name } == false)
        #expect(prompt?.stablePrefix.contains("Nurse") == false)
    }
}
