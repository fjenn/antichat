// R-273 AC4 (Q-015 r5): the turn context names the chat's produced files and their ids (newest first, with the
// current version), so a later turn can pass `revises`; pictures and other chats' files are not listed.
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

struct FileOutContextTests {
    @Test func listsTheChatsFilesNewestFirst() throws {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal), other = ChatRecord(mode: .normal)
        try db.write { db in
            try chat.insert(db)
            try other.insert(db)
            func artifact(_ id: String, _ chatID: String, _ kind: String, _ title: String, _ at: Double, versions: Int) throws {
                try db.execute(sql: "INSERT INTO artifact (id, chat_id, kind, title, created_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [id, chatID, kind, title, at])
                for n in 1...versions {
                    try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, origin, created_at) VALUES (?, ?, 1, ?, 'generated', ?)",
                                   arguments: ["b-\(id)-\(n)", "sha-\(id)-\(n)", "/tmp/\(id)-\(n)", at])
                    try db.execute(sql: "INSERT INTO artifact_version (id, artifact_id, n, blob_id, created_at) VALUES (?, ?, ?, ?, ?)",
                                   arguments: ["v-\(id)-\(n)", id, n, "b-\(id)-\(n)", at])
                }
            }
            try artifact("old", chat.id, "md", "Notes.md", 1, versions: 2)
            try artifact("new", chat.id, "xlsx", "Budget.xlsx", 2, versions: 1)
            try artifact("pic", chat.id, "image", "image.png", 3, versions: 1)
            try artifact("elsewhere", other.id, "docx", "Other.docx", 4, versions: 1)
        }
        let line = try #require(try db.read { try FileOutContext.contextLine(chatID: chat.id, db: $0) })
        #expect(line.hasPrefix(#"Files made in this chat: "Budget.xlsx" artifact_id "new" (version 1); "Notes.md" artifact_id "old" (version 2)"#), "\(line)")
        #expect(!line.contains("image.png") && !line.contains("Other.docx"))
        let empty = ChatRecord(mode: .normal)
        try db.write { try empty.insert($0) }
        #expect(try db.read { try FileOutContext.contextLine(chatID: empty.id, db: $0) } == nil)
    }
}
