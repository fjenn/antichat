// M6 review #11 (an edit of an older version records that version as its parent) and #19 (image refs resolve only
// inside the asking chat).
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatTools

@Suite struct ArtifactStoreReviewTests {
    @Test func editOfAnOlderVersionRecordsItsParent() throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "a")
        let root = try FileOutFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(database: db, mediaRoot: root, incognito: false)
        let v1 = try store.save(chatID: chat.id, kind: "html", filename: "p.html", data: Data("1".utf8), specJSON: nil, messageID: nil)
        let id = v1.artifactID
        let v3 = try ["2", "3"].map { try store.save(chatID: chat.id, kind: "html", filename: "p.html", data: Data($0.utf8),
                                                    specJSON: nil, messageID: nil, revises: id) }.last!
        let v4 = try store.save(chatID: chat.id, kind: "html", filename: "p.html", data: Data("1b".utf8), specJSON: nil,
                                messageID: nil, revises: id, revisesVersion: 1)
        let parent = { (v: SavedArtifact) in try db.read { try ArtifactVersionRecord.fetchOne($0, key: v.versionID)?.parentVersionID } }
        #expect(v4.version == 4)
        #expect(try parent(v4) == v1.versionID, "built from v1, not the newest (v3)")
        let v5 = try store.save(chatID: chat.id, kind: "html", filename: "p.html", data: Data("x".utf8), specJSON: nil,
                                messageID: nil, revises: id)
        #expect(try parent(v5) == v4.versionID && v3.version == 3)
    }

    @Test func imageRefsResolveOnlyInTheirChat() throws {
        let db = try AppDatabase.inMemory()
        let mine = try ChatRepository(db).create(title: "mine"), other = try ChatRepository(db).create(title: "other")
        let root = try FileOutFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("x.png")
        try Data("png".utf8).write(to: png)
        let otherUser = try MessageTree(db).append(chatID: other.id, parentID: nil, role: .user)
        let att = try AttachmentRepository(db).insert(sha256: "p", size: 3, path: png.path, origin: .upload, messageID: otherUser.id,
                                                      displayName: "x.png", uti: "public.png")
        let store = ArtifactStore(database: db, mediaRoot: root, incognito: false)
        let art = try store.save(chatID: other.id, kind: "png", filename: "c.png", data: Data("chart".utf8), specJSON: nil, messageID: nil)
        #expect(store.imageData(ref: att.id, chatID: other.id) == Data("png".utf8))
        #expect(store.imageData(ref: art.artifactID, chatID: other.id) == Data("chart".utf8))
        #expect(store.imageData(ref: att.id, chatID: mine.id) == nil, "another chat's attachment")
        #expect(store.imageData(ref: art.artifactID, chatID: mine.id) == nil, "another chat's artifact")
    }
}
