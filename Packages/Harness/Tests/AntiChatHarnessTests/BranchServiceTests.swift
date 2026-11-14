// M1.T10 AT-006 (unit leg, R-006 AC3): Branch in new chat creates "<title> (branch)" whose messages equal the
// visible path up to that reply (texts, roles, attachments with the same blobs); the original chat's message
// count, leaf and title are unchanged; an untitled chat gets the caller's fallback title.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite("BranchServiceTests") struct BranchServiceTests {
    static let format: @Sendable (String) -> String = { "\($0.isEmpty ? "New chat" : $0) (branch)" }

    func counts(_ h: Harness, _ chatID: String) throws -> Int {
        try h.database.read { db in try MessageRecord.filter(sql: "chat_id = ?", arguments: [chatID]).fetchCount(db) }
    }

    @Test func branchCopiesThePathUpToTheReply() async throws {
        let h = try Harness(script: versionedReply)
        let (u1, a1) = await h.send("first question")
        _ = try await h.log.waitFinished(a1)
        let (_, a2) = await h.send("second question", parent: a1)
        _ = try await h.log.waitFinished(a2)
        try ChatRepository(h.database).rename(h.chatID, title: "Harbour towns")
        let photo = try AttachmentRepository(h.database).insert(
            sha256: String(repeating: "c", count: 64), size: 10, path: "/tmp/001.jpg", origin: .upload, messageID: u1,
            displayName: "001.jpg", uti: "public.jpeg")

        let before = (count: try counts(h, h.chatID), chat: try ChatRepository(h.database).chat(h.chatID))
        let newID = try BranchService(h.database).branch(upTo: a1, title: Self.format)

        // The new chat: title, and the path up to and including the first reply.
        let branched = try #require(try ChatRepository(h.database).chat(newID))
        #expect(branched.title == "Harbour towns (branch)")
        let tree = MessageTree(h.database)
        let path = try tree.visiblePath(newID)
        #expect(path.map(\.role) == [.user, .assistant])
        #expect(try path.map { try h.persistedText($0.id) } == ["first question", "Answer v1."])
        #expect(Set(path.map(\.id)).isDisjoint(with: [u1, a1]))
        let copied = try AttachmentRepository(h.database).attachments(messageID: path[0].id)
        #expect(copied.map(\.blobID) == [photo.blobID])
        #expect(branched.leafMessageID == path.last?.id)

        // The original: count, leaf and title unchanged.
        let after = try ChatRepository(h.database).chat(h.chatID)
        #expect(try counts(h, h.chatID) == before.count)
        #expect(after?.leafMessageID == before.chat?.leafMessageID)
        #expect(after?.title == "Harbour towns")
        #expect(try tree.visiblePath(h.chatID).count == 4)
    }

    @Test func untitledChatGetsTheFallbackTitle() async throws {
        let h = try Harness(script: versionedReply)
        let (_, a) = await h.send("hi")
        _ = try await h.log.waitFinished(a)
        let newID = try BranchService(h.database).branch(upTo: a, title: Self.format)
        #expect(try ChatRepository(h.database).chat(newID)?.title == "New chat (branch)")
    }

    @Test func branchFromAnOlderVersionCopiesThatVersion() async throws {
        let h = try Harness(script: versionedReply)
        let (_, a) = await h.send("go")
        _ = try await h.log.waitFinished(a)
        let a2 = StorageID.make()
        await h.controller.start(RegenerateService.request(a), assistantID: a2)
        _ = try await h.log.waitFinished(a2)
        // Versions viewer → version 1 → Branch in new chat.
        let newID = try BranchService(h.database).branch(upTo: a, title: Self.format)
        let path = try MessageTree(h.database).visiblePath(newID)
        #expect(try path.map { try h.persistedText($0.id) } == ["go", "Answer v1."])
        #expect(try MessageTree(h.database).visiblePath(h.chatID).last?.id == a2)  // original still shows v2
    }
}
