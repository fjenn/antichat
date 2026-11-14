// AT-296 leg (1) (M1.T04): tree operations on fixture chat `tree-basic`.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("MessageTreeTests") struct MessageTreeTests {
    @Test func treeBasicIsALinearPath() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        #expect(try tree.visiblePath(f.chatID).map(\.id) == f.ids)
        let chat = try #require(try ChatRepository(f.database).chat(f.chatID))
        #expect(chat.leafMessageID == f.ids.last)
        try expectValidTrees(f.database)
    }

    /// AT-296 (1): after 3 regenerates and 2 edits on `tree-basic`, `message` rows have the right `parent_id`,
    /// the sibling counts are 4 and 3, and `chat.leaf_message_id` is the last node of the active path.
    @Test func threeRegeneratesAndTwoEdits() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        let (u2, a2, a3) = (f.ids[2], f.ids[3], f.ids[5])
        _ = a2

        var regenerated: [MessageRecord] = []
        for i in 1...3 {
            regenerated.append(try tree.insertSibling(of: a3, parts: [.text("answer 3, take \(i + 1)")]))
            #expect(try tree.versionInfo(regenerated.last!.id) == (i + 1, i + 1))
            #expect(try tree.visiblePath(f.chatID).last?.id == regenerated.last!.id)
        }
        let a3Siblings = try tree.siblings(of: a3)
        #expect(a3Siblings.count == 4)
        #expect(Set(a3Siblings.map(\.parentID)) == [f.ids[4]])
        #expect(a3Siblings.allSatisfy { $0.role == .assistant })
        #expect(a3Siblings.map(\.position) == [0, 1, 2, 3])

        var edits: [(user: MessageRecord, reply: MessageRecord)] = []
        for i in 1...2 {
            let user = try tree.insertSibling(of: u2, parts: [.text("question 2, edit \(i)")])
            let reply = try tree.append(chatID: f.chatID, parentID: user.id, role: .assistant,
                                        parts: [.text("answer to edit \(i)")])
            edits.append((user, reply))
        }
        let u2Siblings = try tree.siblings(of: u2)
        #expect(u2Siblings.count == 3)
        #expect(Set(u2Siblings.map(\.parentID)) == [f.ids[1]])
        #expect(u2Siblings.allSatisfy { $0.role == .user })
        #expect(try tree.versionInfo(edits[1].user.id) == (3, 3))
        #expect(try tree.versionInfo(u2) == (1, 3))

        let path = try tree.visiblePath(f.chatID)
        #expect(path.map(\.id) == [f.ids[0], f.ids[1], edits[1].user.id, edits[1].reply.id])
        let chat = try #require(try ChatRepository(f.database).chat(f.chatID))
        #expect(chat.leafMessageID == path.last?.id)
        #expect(chat.leafMessageID == edits[1].reply.id)

        try f.database.read { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") == 6 + 3 + 4)
            #expect(try String.fetchOne(db, sql: "SELECT parent_id FROM message WHERE id = ?",
                                        arguments: [edits[0].reply.id]) == edits[0].user.id)
            #expect(try TreeInvariants.violations(db) == [])
        }

        // Switching back to the original u2 restores its subtree, with a3's last regenerate still active there.
        try tree.setActive(u2)
        let restored = try tree.visiblePath(f.chatID)
        #expect(restored.map(\.id) == Array(f.ids[0...4]) + [regenerated.last!.id])
        #expect(try ChatRepository(f.database).chat(f.chatID)?.leafMessageID == regenerated.last!.id)
        // Switching versions changes active_child_id only: no rows added.
        #expect(try f.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") } == 13)
        // Back to version 1 of the reply.
        try tree.setActive(a3)
        #expect(try tree.visiblePath(f.chatID).last?.id == a3)
        #expect(try tree.versionInfo(a3) == (1, 4))
    }

    @Test func editingTheFirstMessageMakesSiblingRoots() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        let root2 = try tree.insertSibling(of: f.ids[0], parts: [.text("question 1, edited")])
        #expect(root2.parentID == nil)
        #expect(try tree.versionInfo(root2.id) == (2, 2))
        #expect(try tree.visiblePath(f.chatID).map(\.id) == [root2.id])
        try tree.setActive(f.ids[0])
        #expect(try tree.visiblePath(f.chatID).map(\.id) == f.ids)
        try expectValidTrees(f.database)
    }

    @Test func branchCopyCopiesThePathAndLeavesTheOriginal() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        _ = try tree.insertSibling(of: f.ids[5], parts: [.text("other answer")])
        let before = try f.database.read { (db: Database) throws in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE chat_id = ?", arguments: [f.chatID]),
             try ChatRecord.fetchOne(db, key: f.chatID)?.leafMessageID)
        }
        let newChat = try tree.branchCopy(upTo: f.ids[3], title: "tree-basic (branch)")
        let copied = try tree.visiblePath(newChat)
        #expect(copied.count == 4)
        #expect(copied.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(Set(copied.map(\.id)).isDisjoint(with: f.ids))
        #expect(copied.last?.provenance?.modelSHA == "sha256-fixture")
        let texts = try copied.map { try MessageRepository(f.database).parts(of: $0.id).first?.body }
        #expect(texts == ["question 1", "answer 1", "question 2", "answer 2"])
        let chat = try #require(try ChatRepository(f.database).chat(newChat))
        #expect(chat.title == "tree-basic (branch)")
        #expect(chat.leafMessageID == copied.last?.id)
        let after = try f.database.read { (db: Database) throws in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE chat_id = ?", arguments: [f.chatID]),
             try ChatRecord.fetchOne(db, key: f.chatID)?.leafMessageID)
        }
        #expect(after == before)
        try expectValidTrees(f.database)
    }

    @Test func appendRejectsAParentFromAnotherChat() throws {
        let f = try TreeFixtures.treeBasic()
        let other = try ChatRepository(f.database).create(title: "other")
        #expect(throws: StorageError.self) {
            try MessageTree(f.database).append(chatID: other.id, parentID: f.ids[0], role: .user)
        }
        #expect(throws: StorageError.notFound("message nope")) { try MessageTree(f.database).setActive("nope") }
    }

    @Test func deletingAMessageRemovesItsSubtree() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        _ = try tree.insertSibling(of: f.ids[2], parts: [.text("edit")])
        try f.database.write { (db: Database) throws in
            _ = try MessageRecord.deleteOne(db, key: f.ids[2])
            try MessageTree.refreshLeaf(f.chatID, db: db)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") == 3)
            #expect(try TreeInvariants.violations(db) == [])
        }
    }

    @Test func chatModeIsLockedAfterTheFirstMessage() throws {
        let database = try AppDatabase.inMemory()
        let chats = ChatRepository(database)
        let chat = try chats.create(title: "mode")
        try chats.setMode(chat.id, .evil)  // no message yet: allowed
        try MessageTree(database).append(chatID: chat.id, parentID: nil, role: .user, parts: [.text("hi")])
        #expect(throws: DatabaseError.self) { try chats.setMode(chat.id, .normal) }
        #expect(try chats.chat(chat.id)?.mode == .evil)
    }

    @Test func storageIDsAreTimeOrderedUUIDv7() throws {
        let ids = (0..<2000).map { _ in StorageID.make() }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        for id in ids.prefix(10) {
            let uuid = try #require(UUID(uuidString: id))
            #expect(uuid.uuid.6 >> 4 == 7)
            #expect(uuid.uuid.8 >> 6 == 0b10)
        }
    }
}
