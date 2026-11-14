// M1.T08 step 6: a paste card is stored as `attachment` + `file_blob` (`origin=upload`); Incognito keeps the
// bytes in memory (nothing under the media root).
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct PastedTextAttachmentStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paste-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func onDiskWritesTheBlobFileAndRows() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase.onDisk(at: root.appendingPathComponent("antichat.sqlite"))
        let store = PastedTextAttachmentStore(database: db, mediaRoot: root.appendingPathComponent("Media"))
        let text = String(repeating: "pasted ", count: 2_000)
        let a = try store.save(text: text, displayName: "Pasted text", messageID: nil,
                               now: Date(timeIntervalSince1970: 1_793_361_600))
        #expect(a.uti == "public.plain-text")
        #expect(a.messageID == nil)
        let blob = try #require(try AttachmentRepository(db).blob(id: a.blobID))
        #expect(blob.origin == .upload)
        #expect(blob.size == Int64(text.utf8.count))
        #expect(blob.path.hasPrefix(root.appendingPathComponent("Media/2026").path))
        #expect(blob.path.hasSuffix("\(blob.sha256).txt"))
        #expect(FileManager.default.fileExists(atPath: blob.path))
        #expect(try store.text(of: a) == text)

        // The same paste again shares the blob (sha256 is unique).
        let b = try store.save(text: text, displayName: "Pasted text", messageID: nil)
        #expect(b.blobID == a.blobID)
        #expect(b.id != a.id)
    }

    @Test func incognitoKeepsBytesInMemory() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase.inMemory()
        let store = PastedTextAttachmentStore(database: db, mediaRoot: root)
        let a = try store.save(text: "secret paste", displayName: "Pasted text", messageID: nil)
        let blob = try #require(try AttachmentRepository(db).blob(id: a.blobID))
        #expect(blob.path.hasPrefix("memory:"))
        #expect(!FileManager.default.fileExists(atPath: root.path), "nothing reaches disk")
        #expect(try store.text(of: a) == "secret paste")
    }
}
