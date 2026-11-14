// AT-287 AC4 (R-287, M4.T09): every artifact_version row stores its parent version and its operation
// (v30_photo_lineage), for every operation; the column refuses anything else.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("ArtifactLineageTests") struct ArtifactLineageTests {
    @Test func parentAndOperationStoredForEachOperation() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "pictures")
        let repo = ArtifactRepository(database)
        let artifact = try repo.create(chatID: chat.id, kind: "image", title: "image.png")
        var previous: ArtifactVersionRecord?
        for (i, op) in ArtifactOperation.allCases.enumerated() {
            let blob = try AttachmentRepository(database).insert(sha256: "sha\(i)", size: 1, path: "Media/2026/\(i).png", origin: .generated,
                                                                  messageID: nil, displayName: "image.png", uti: "public.png")
            let v = try repo.addVersion(artifactID: artifact.id, blobID: blob.blobID, operation: op)
            #expect(v.operation == op.rawValue)
            #expect(v.parentVersionID == previous?.id)
            previous = v
        }
        let stored = try repo.versions(artifactID: artifact.id)
        #expect(stored.map(\.operation) == ArtifactOperation.allCases.map(\.rawValue))
        #expect(stored.first?.parentVersionID == nil)
        #expect(zip(stored.dropFirst(), stored).allSatisfy { $0.parentVersionID == $1.id })
    }

    @Test func documentsHaveNoOperationAndUnknownOperationsAreRefused() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "files")
        let blob = try AttachmentRepository(database).insert(sha256: "dd", size: 1, path: "p", origin: .generated, messageID: nil,
                                                              displayName: "a.pdf", uti: "com.adobe.pdf")
        let repo = ArtifactRepository(database)
        let artifact = try repo.create(chatID: chat.id, kind: "pdf", title: "a.pdf")
        let v = try repo.addVersion(artifactID: artifact.id, blobID: blob.blobID)
        #expect(v.operation == nil)
        #expect(throws: (any Error).self) {
            try database.write { db in
                try db.execute(sql: "UPDATE artifact_version SET operation = 'teleport' WHERE id = ?", arguments: [v.id])
            }
        }
    }
}
