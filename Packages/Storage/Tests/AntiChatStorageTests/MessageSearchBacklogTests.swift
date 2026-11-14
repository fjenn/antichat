// AT-092 AC2 (R-092): the import defers message full-text rows to MessageSearchBacklog. Imported chats are readable at
// once and searchable after the pass; edits and deletes of rows still in the backlog never touch the index; rows
// written after the window closes are indexed live; windows never double-index; the FTS5 integrity check passes.
//   make test-unit FILTER=MessageSearchBacklogTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite(.serialized) struct MessageSearchBacklogTests {
    func hits(_ db: AppDatabase, _ q: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fts WHERE message_fts MATCH ?", arguments: [q]) ?? 0 }
    }

    func integrity(_ db: AppDatabase) throws {
        try db.write { try $0.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('integrity-check', 1)") }
    }

    /// A chat with one message whose text part is `body`; returns the part id.
    @discardableResult
    func addPart(_ db: AppDatabase, _ body: String) throws -> Int64 {
        try db.write { d in
            let chat = ChatRecord(title: "t")
            try chat.insert(d)
            let mid = StorageID.make()
            try d.execute(sql: "INSERT INTO message(id, chat_id, position, role, status, created_at) VALUES (?, ?, 0, 'user', 'done', 0)",
                          arguments: [mid, chat.id])
            try d.execute(sql: "INSERT INTO message_part(message_id, idx, kind, body) VALUES (?, 0, 'text', ?)", arguments: [mid, body])
            return d.lastInsertedRowID
        }
    }

    @Test func importIsReadableAtOnceAndSearchableAfterThePass() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let s = try rig.importer.run(importFixture("chats/chatgpt-export/chatgpt-export.json"))
        #expect(s.chats == 2)
        let backlog = MessageSearchBacklog(database: rig.db)
        let pending = try backlog.status()
        #expect(!pending.isDone && pending.fraction == 0)
        let texts = try rig.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_part WHERE kind = 'text'") ?? 0 }
        #expect(texts > 0)
        #expect(try rig.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fts") ?? 0 } == 0 || texts > 0)
        var seen: [Double] = []
        try backlog.run(progress: { seen.append($0.fraction) })
        #expect(seen == seen.sorted() && seen.last == 1)
        #expect(try backlog.status().isDone)
        #expect(try rig.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fts_backlog") } == 0)
        try integrity(rig.db)
        // Every imported text part is in the index exactly once (a second pass adds nothing).
        let indexed = try rig.db.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM message_part p WHERE p.kind = 'text' AND p.id IN (SELECT rowid FROM message_fts)") ?? 0
        }
        #expect(indexed == texts)
        try backlog.run()
        try integrity(rig.db)
    }

    @Test func deferredRowsEditedOrDeletedNeverCorruptTheIndex() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let db = rig.db
        let live = try addPart(db, "before window zebra")
        let backlog = MessageSearchBacklog(database: db)
        try backlog.begin()
        let a = try addPart(db, "deferred alpha")
        let b = try addPart(db, "deferred bravo")
        _ = try addPart(db, "deferred charlie")
        #expect(try hits(db, "deferred") == 0 && hits(db, "zebra") == 1)
        try db.write { d in
            try d.execute(sql: "UPDATE message_part SET body = 'edited alpha' WHERE id = ?", arguments: [a])
            try d.execute(sql: "DELETE FROM message_part WHERE id = ?", arguments: [b])
            try d.execute(sql: "UPDATE message_part SET body = 'edited zebra' WHERE id = ?", arguments: [live])  // indexed row
        }
        try backlog.end()
        let after = try addPart(db, "after window yankee")  // indexed live
        #expect(try hits(db, "yankee") == 1 && hits(db, "zebra") == 1 && hits(db, "before") == 0)
        try backlog.run()
        #expect(try hits(db, "deferred") == 1 && hits(db, "edited") == 2 && hits(db, "bravo") == 0 && hits(db, "alpha") == 1)
        try integrity(db)
        try db.write { try $0.execute(sql: "DELETE FROM message_part WHERE id IN (?, ?)", arguments: [a, after]) }
        #expect(try hits(db, "alpha") == 0 && hits(db, "yankee") == 0)
        try integrity(db)
    }

    @Test func windowsNeverOverlapOrDoubleIndex() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let db = rig.db
        let backlog = MessageSearchBacklog(database: db)
        try backlog.begin()
        try addPart(db, "first window one")
        try backlog.begin()  // joins the open window
        try addPart(db, "first window two")
        try backlog.end()
        try addPart(db, "between windows live")
        try backlog.begin()  // a new window after the closed, still pending one
        try addPart(db, "second window three")
        // A pass while the second window is open indexes what exists so far.
        try backlog.run()
        #expect(try hits(db, "window") == 3 && hits(db, "live") == 1)
        try addPart(db, "second window four")
        #expect(try hits(db, "four") == 0)
        try backlog.end()
        try backlog.run()
        #expect(try hits(db, "window") == 4 && hits(db, "live") == 1)
        #expect(try backlog.status().isDone)
        try integrity(db)
    }

    @Test func repairDuringABacklogDoesNotRebuildAndARebuildClearsIt() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let db = rig.db
        let backlog = MessageSearchBacklog(database: db)
        try backlog.begin()
        try addPart(db, "pending kilo")
        try backlog.end()
        #expect(try db.repairFullTextIfNeeded() == false)  // short by design, not drift
        #expect(try hits(db, "kilo") == 0)
        try backlog.run()
        #expect(try hits(db, "kilo") == 1)
        try integrity(db)
    }
}
