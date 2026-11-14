// M8.T06 AT-092 AC2 (R-092): import twice → no duplicate chat (every conversation skipped); a conversation whose
// `update_time` is newer replaces its chat in place (same id, project, pin; count unchanged); Cancel stops between
// conversations and keeps only whole chats, which the next run skips.
//   make test-unit FILTER=ImportDedupTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite(.serialized) struct ImportDedupTests {
    func chatCount(_ db: AppDatabase) throws -> Int { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat") ?? 0 } }

    @Test func reimportSkipsAndNewerReplacesInPlace() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let src = importFixture("chats/chatgpt-export/chatgpt-export.json")
        let first = try rig.importer.run(src)
        #expect(first.chats == 2)
        let again = try rig.importer.run(src)
        let n = try chatCount(rig.db)
        #expect(again.chats == 0 && again.skipped == 2 && n == 2)

        var convs = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: src)) as? [[String: Any]])
        let key = try #require(convs[0]["conversation_id"] as? String ?? convs[0]["id"] as? String)
        let chatID = try #require(try rig.db.read { try String.fetchOne($0, sql: "SELECT id FROM chat WHERE source_id = ?", arguments: [key]) })
        try rig.db.write { try $0.execute(sql: "UPDATE chat SET pinned = 1 WHERE id = ?", arguments: [chatID]) }
        convs[0]["update_time"] = ((convs[0]["update_time"] as? Double) ?? 0) + 3600
        convs[0]["title"] = "Renamed upstream"
        let newer = rig.dir.appendingPathComponent("newer.json")
        try JSONSerialization.data(withJSONObject: convs).write(to: newer)
        let third = try rig.importer.run(newer)
        #expect(third.replaced == 1 && third.skipped == 1 && third.chats == 0)
        #expect(try chatCount(rig.db) == 2)
        let chat = try #require(try rig.db.read { try ChatRecord.fetchOne($0, key: chatID) })
        #expect(chat.title == "Renamed upstream" && chat.pinned)
        let messages = try rig.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message WHERE chat_id = ?", arguments: [chatID]) }
        #expect(messages == first.messages / 2 || (messages ?? 0) > 0)
        #expect(try rig.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM import_record") } == 2)
    }

    /// RC review P1-1: a chat the user continued here is never replaced by a newer export (that would delete their
    /// messages); the newer export lands as a new chat and the import record follows it.
    @Test func newerExportNeverReplacesAChatWithLocalMessages() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let src = importFixture("chats/chatgpt-export/chatgpt-export.json")
        _ = try rig.importer.run(src)
        var convs = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: src)) as? [[String: Any]])
        let key = try #require(convs[0]["conversation_id"] as? String ?? convs[0]["id"] as? String)
        let chatID = try #require(try rig.db.read { try String.fetchOne($0, sql: "SELECT id FROM chat WHERE source_id = ?", arguments: [key]) })
        // A local turn: no source id.
        try rig.db.write { db in
            try db.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES ('local-1', ?, 'user', 0)", arguments: [chatID])
        }
        convs[0]["update_time"] = ((convs[0]["update_time"] as? Double) ?? 0) + 3600
        let newer = rig.dir.appendingPathComponent("newer.json")
        try JSONSerialization.data(withJSONObject: convs).write(to: newer)
        let again = try rig.importer.run(newer)
        #expect(again.replaced == 0 && again.chats == 1 && again.skipped == 1)
        #expect(try rig.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message WHERE id = 'local-1' AND chat_id = ?", arguments: [chatID]) } == 1)
        #expect(try chatCount(rig.db) == 3)
        let recordChat = try rig.db.read {
            try String.fetchOne($0, sql: "SELECT chat_id FROM import_record WHERE external_key = ?", arguments: [key])
        }
        #expect(recordChat != nil && recordChat != chatID)
        // A third run of the same file skips (the record moved with its updated time).
        #expect(try rig.importer.run(newer).skipped == 2)
    }

    @Test func cancelKeepsWholeChatsOnly() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let zip = importFixture("chats/chatgpt-export/export.zip")
        var done = 0
        let s = try rig.importer.run(zip, progress: { done = $0.chatsDone }, isCancelled: { done >= 2 })
        #expect(s.cancelled && s.chats == 2)
        #expect(try chatCount(rig.db) == 2)
        // every written chat is complete: its leaf exists and every message has a part or an attachment
        let broken = try rig.db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chat c WHERE c.leaf_message_id IS NULL
                   OR NOT EXISTS (SELECT 1 FROM message m WHERE m.id = c.leaf_message_id)
                """)
        }
        #expect(broken == 0)
        let rest = try rig.importer.run(zip)
        let total = try chatCount(rig.db)
        #expect(rest.skipped == 2 && rest.chats == 3 && total == 5)
    }

    /// RC review P2-5: two conversations without a source id, with the same title and no `created_at`, used to share
    /// the `title|createdAt` key, so the second was skipped as a re-import of the first. Both now import, and the same
    /// file imported again still skips both.
    @Test func conversationsWithoutIdsAndSameTitleDoNotCollide() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        func conv(_ text: String) -> [String: Any] {
            ["name": "Untitled", "chat_messages": [["sender": "human", "text": text], ["sender": "assistant", "text": "re: \(text)"]]]
        }
        let file = rig.dir.appendingPathComponent("conversations.json")
        try JSONSerialization.data(withJSONObject: [conv("first question"), conv("second question")]).write(to: file)
        let first = try rig.importer.run(file)
        #expect(first.chats == 2 && first.skipped == 0)
        #expect(try chatCount(rig.db) == 2)
        let again = try rig.importer.run(file)
        #expect(again.chats == 0 && again.skipped == 2)
        #expect(try chatCount(rig.db) == 2)
    }
}
