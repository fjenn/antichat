// M1.T10 AT-006 (unit leg, R-006 AC1–2): Edit sends the new text as version 2 of that turn (a user sibling with
// its own reply); ‹ 1/2 › returns to the original branch with its original reply intact; attachments the editor
// kept are carried to the new version (same blob, no file copy), removed ones are not, the original keeps all.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite("EditServiceTests") struct EditServiceTests {
    @Test func editCreatesVersionTwoAndKeepsTheOriginalBranch() async throws {
        let h = try Harness(script: versionedReply)
        let (u, a) = await h.send("first")
        _ = try await h.log.waitFinished(a)
        // A second turn under the original, so the original branch has more than one reply.
        let (u1b, a1b) = await h.send("follow-up", parent: a)
        _ = try await h.log.waitFinished(a1b)

        let u2 = StorageID.make()
        let a2 = StorageID.make()
        await h.controller.start(EditService.request(userID: u, newUserID: u2, text: "edited"), assistantID: a2)
        let r = try await h.log.waitFinished(a2)
        #expect(r.userID == u2 && r.userVersion == 2 && r.userVersionCount == 2)
        let tree = MessageTree(h.database)
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u2, a2])
        #expect(try h.persistedText(u2) == "edited")

        // ‹ 1/2 on the user bubble: the original branch, replies intact.
        let service = RegenerateService(h.database)
        #expect(try service.step(from: u2, by: -1) == u)
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u, a, u1b, a1b])
        #expect(try h.persistedText(u) == "first")
        #expect(try h.persistedText(a) == "Answer v1.")
        #expect(try tree.versionInfo(u) == (1, 2))
        // › 2/2: back to the edit.
        #expect(try service.step(from: u, by: 1) == u2)
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u2, a2])
    }

    @Test func editCarriesKeptAttachmentsWithTheSameBlob() async throws {
        let h = try Harness(script: versionedReply)
        let (u, a) = await h.send("look at these")
        _ = try await h.log.waitFinished(a)
        let repo = AttachmentRepository(h.database)
        let photo = try repo.insert(sha256: String(repeating: "a", count: 64), size: 10, path: "/tmp/001.jpg",
                                    origin: .upload, messageID: u, displayName: "001.jpg", uti: "public.jpeg")
        let second = try repo.insert(sha256: String(repeating: "b", count: 64), size: 10, path: "/tmp/002.jpg",
                                     origin: .upload, messageID: u, displayName: "002.jpg", uti: "public.jpeg")
        #expect(try EditService(h.database).attachments(of: u).map(\.id) == [photo.id, second.id])

        // The editor removed the second photo.
        let u2 = StorageID.make()
        let a2 = StorageID.make()
        await h.controller.start(EditService.request(userID: u, newUserID: u2, text: "just this one",
                                                     keptAttachmentIDs: [photo.id]), assistantID: a2)
        _ = try await h.log.waitFinished(a2)
        let carried = try repo.attachments(messageID: u2)
        #expect(carried.count == 1)
        #expect(carried.first?.blobID == photo.blobID)
        #expect(carried.first?.id != photo.id)
        #expect(carried.first?.displayName == "001.jpg")
        #expect(try repo.attachments(messageID: u).count == 2)  // the original keeps both
        #expect(try h.database.read { db in try FileBlobRecord.fetchCount(db) } == 2)  // no blob copy

        // nil = keep all.
        let u3 = StorageID.make()
        let a3 = StorageID.make()
        await h.controller.start(EditService.request(userID: u, newUserID: u3, text: "both"), assistantID: a3)
        _ = try await h.log.waitFinished(a3)
        #expect(try repo.attachments(messageID: u3).map(\.blobID) == [photo.blobID, second.blobID])
        #expect(try MessageTree(h.database).versionInfo(u3) == (3, 3))
    }
}
