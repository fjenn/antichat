// M8.T04 AT-064 (R-064 AC2): the ScriptedEngine captured request of 2 chats in a project carries the project's
// instructions in the stable layer (after custom instructions, before memory); a chat outside does not; an edit after
// a chat's first send leaves that chat's prefix byte-identical (frozen) and reaches the next new chat.
//   make test-unit FILTER=ProjectLayerTests
import AntiChatEngineProtocol
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ProjectLayerTests {
    static func turn(_ db: AppDatabase, chatID: String, text: String = "hi") async throws -> ComposedPrompt? {
        let c = TurnController(chatID: chatID, database: db,
                               engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok","delayMs":1}"#))) {
            .scripted("inline")
        }
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a, timeout: .seconds(30))
        return await c.lastPrompt
    }

    @Test func instructionsRideTheStableLayerOfProjectChatsOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("projlayer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let store = ProjectStore(database: db)
        let p = try store.create(name: "Dutch")
        try store.setInstructions(p.id, "Always answer in formal Dutch.")
        let repo = ChatRepository(db)
        let a = try repo.create(projectID: p.id).id, b = try repo.create(projectID: p.id).id, outside = try repo.create().id

        let pa = try #require(try await Self.turn(db, chatID: a))
        let pb = try #require(try await Self.turn(db, chatID: b))
        let po = try #require(try await Self.turn(db, chatID: outside))
        for prompt in [pa, pb] {
            #expect(prompt.stablePrefix.contains("\(ProjectLayer.heading)\nAlways answer in formal Dutch."))
            let ids = prompt.manifest.sections.map(\.id)
            #expect(ids.firstIndex(of: PromptLayerID.project).map { $0 > (ids.firstIndex(of: PromptLayerID.base) ?? 0) } == true)
        }
        #expect(!po.stablePrefix.contains("formal Dutch") && !po.manifest.sections.map(\.id).contains(PromptLayerID.project))

        try store.setInstructions(p.id, "Answer in English.")
        let pa2 = try #require(try await Self.turn(db, chatID: a, text: "again"))
        #expect(pa2.stableSHA256 == pa.stableSHA256)  // frozen at the first send
        let fresh = try repo.create(projectID: p.id).id
        let pf = try #require(try await Self.turn(db, chatID: fresh))
        #expect(pf.stablePrefix.contains("Answer in English.") && !pf.stablePrefix.contains("formal Dutch"))
        #expect(ProjectLayer.render("  ") == "")
    }
}
