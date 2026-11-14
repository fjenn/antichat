// M4.T10: v13_artifact — artifact rows and the n = 1, 2, … version chain (FileCard "Version {n}", SidePanel picker).
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct ArtifactRepositoryTests {
    @Test func versionChainNumbersFromOne() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "files")
        let attachments = AttachmentRepository(database)
        let a = try attachments.insert(sha256: "aa", size: 3, path: "Media/2026/aa.pdf", origin: .generated, messageID: nil,
                                       displayName: "a.pdf", uti: "com.adobe.pdf")
        let b = try attachments.insert(sha256: "bb", size: 4, path: "Media/2026/bb.pdf", origin: .generated, messageID: nil,
                                       displayName: "a.pdf", uti: "com.adobe.pdf")
        let repo = ArtifactRepository(database)
        let artifact = try repo.create(chatID: chat.id, kind: "pdf", title: "a.pdf")
        let v1 = try repo.addVersion(artifactID: artifact.id, blobID: a.blobID)
        let v2 = try repo.addVersion(artifactID: artifact.id, blobID: b.blobID, specJSON: "{}")
        #expect(v1.n == 1 && v2.n == 2)
        #expect(try repo.versions(artifactID: artifact.id).map(\.n) == [1, 2])
        #expect(try repo.artifact(id: artifact.id)?.title == "a.pdf")
    }

    @Test func deletingTheChatRemovesArtifacts() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "x")
        let blob = try AttachmentRepository(database).insert(sha256: "cc", size: 1, path: "p", origin: .generated,
                                                              messageID: nil, displayName: "c.csv", uti: "public.comma-separated-values-text")
        let repo = ArtifactRepository(database)
        let artifact = try repo.create(chatID: chat.id, kind: "csv", title: "c.csv")
        try repo.addVersion(artifactID: artifact.id, blobID: blob.blobID)
        try database.write { db in _ = try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [chat.id]) }
        #expect(try repo.artifact(id: artifact.id) == nil)
        #expect(try repo.versions(artifactID: artifact.id).isEmpty)
    }
}
