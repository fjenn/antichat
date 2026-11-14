// M6.T13 steps 5 and 7 (R-016 AC5, R-017 AC2; AT-017 check 2 in-process leg): ChatFilesQuery lists a chat's attached
// files (attachment rows of its messages) and produced files (artifacts at their latest version) with name, kind,
// size and date, newest first, and nothing from other chats.
//   make test-unit FILTER=ChatFilesQueryTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct ChatFilesQueryTests {
    @Test func attachedAndProducedNewestFirst() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "files"), other = try ChatRepository(database).create(title: "other")
        let user = try MessageTree(database).append(chatID: chat.id, parentID: nil, role: .user)
        let otherUser = try MessageTree(database).append(chatID: other.id, parentID: nil, role: .user)
        let attachments = AttachmentRepository(database)
        let up = try attachments.insert(sha256: "u1", size: 1200, path: "/m/u1.pdf", origin: .upload, messageID: user.id,
                                        displayName: "report.pdf", uti: "com.adobe.pdf")
        _ = try attachments.insert(sha256: "u2", size: 5, path: "/m/u2.csv", origin: .upload, messageID: otherUser.id,
                                   displayName: "elsewhere.csv", uti: "public.comma-separated-values-text")
        let g1 = try attachments.insert(sha256: "g1", size: 300, path: "/m/g1.xlsx", origin: .generated, messageID: nil,
                                        displayName: "Budget.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet")
        let g2 = try attachments.insert(sha256: "g2", size: 450, path: "/m/g2.xlsx", origin: .generated, messageID: nil,
                                        displayName: "Budget.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet")
        let repo = ArtifactRepository(database)
        let art = try repo.create(chatID: chat.id, kind: "xlsx", title: "Budget.xlsx", now: Date().addingTimeInterval(10))
        try repo.addVersion(artifactID: art.id, blobID: g1.blobID, now: Date().addingTimeInterval(10))
        try repo.addVersion(artifactID: art.id, blobID: g2.blobID, now: Date().addingTimeInterval(20))

        let files = try ChatFilesQuery(database).files(chatID: chat.id)
        #expect(files.map(\.name) == ["Budget.xlsx", "report.pdf"])
        let produced = try #require(files.first)
        #expect(produced.origin == .produced && produced.version == 2 && produced.size == 450 && produced.path == "/m/g2.xlsx")
        #expect(produced.kind == "xlsx" && produced.id == art.id)
        let attached = files[1]
        #expect(attached.origin == .attached && attached.size == 1200 && attached.id == up.id && attached.version == nil)
        #expect(!attached.exists, "the media-store file is gone → the deleted state")
        #expect(try ChatFilesQuery(database).files(chatID: other.id).map(\.name) == ["elsewhere.csv"])
    }
}

/// M6 review #21: an attached file is dated by its attachment, not by the first upload of its bytes anywhere.
@Suite struct ChatFilesQueryReattachTests {
    @Test func reattachedFileShowsTodaysDate() throws {
        let database = try AppDatabase.inMemory()
        let old = try ChatRepository(database).create(title: "old"), chat = try ChatRepository(database).create(title: "new")
        let oldUser = try MessageTree(database).append(chatID: old.id, parentID: nil, role: .user)
        let user = try MessageTree(database).append(chatID: chat.id, parentID: nil, role: .user)
        let attachments = AttachmentRepository(database)
        let year = Date().addingTimeInterval(-365 * 86_400)
        _ = try attachments.insert(sha256: "same", size: 10, path: "/m/same.pdf", origin: .upload, messageID: oldUser.id,
                                   displayName: "report.pdf", uti: "com.adobe.pdf", now: year)
        let now = Date()
        _ = try attachments.insert(sha256: "same", size: 10, path: "/m/same.pdf", origin: .upload, messageID: user.id,
                                   displayName: "report.pdf", uti: "com.adobe.pdf", now: now)
        let f = try #require(try ChatFilesQuery(database).files(chatID: chat.id).first)
        #expect(abs(f.date.timeIntervalSince(now)) < 1, "dated \(f.date), the blob's first upload")
    }
}
