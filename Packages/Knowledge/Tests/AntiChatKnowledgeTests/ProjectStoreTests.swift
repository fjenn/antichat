// M8.T04 AT-064 unit leg (R-064 AC1–AC4): CRUD + validation, limits (100 copied files OK / 101st rejected; the 2 GB
// sum boundary with sparse-file sizes), move in/out keeps the frozen instructions, instructions frozen at the first
// send, delete-with-keep (project_id NULL for every chat) vs delete-with-chats (chats + FTS rows gone), refcounted
// blob deletion, project-only memory default global and cascaded with the project.
//   make test-unit FILTER=ProjectStoreTests
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatKnowledge

@Suite struct ProjectStoreTests {
    func store() throws -> ProjectStore { ProjectStore(database: try AppDatabase.inMemory()) }

    func chat(_ s: ProjectStore, _ title: String, project: String? = nil) throws -> String {
        let c = try ChatRepository(s.database).create(title: title, projectID: project)
        return c.id
    }

    @Test func createRenameIconAndValidation() throws {
        let s = try store()
        let p = try s.create(name: "  Thesis  ", icon: "graduationcap")
        #expect(p.name == "Thesis" && p.icon == "graduationcap" && p.memoryMode == .global)
        #expect(throws: ProjectError.invalidName) { try s.create(name: "   ") }
        #expect(throws: ProjectError.invalidName) { try s.create(name: String(repeating: "x", count: 61)) }
        #expect(try s.create(name: "Odd", icon: "not.a.symbol").icon == "folder")
        try s.rename(p.id, to: "Thesis 2026")
        try s.setIcon(p.id, "book")
        #expect(try s.project(p.id)?.name == "Thesis 2026" && s.project(p.id)?.icon == "book")
        _ = try chat(s, "a", project: p.id)
        #expect(try s.summaries().first { $0.id == p.id }?.chatCount == 1)
    }

    @Test func limitsAreCheckedBeforeAnyCopy() throws {
        let s = try store()
        let p = try s.create(name: "Docs")
        #expect(try s.admit(p.id, sizes: Array(repeating: 10, count: 101)) == 100)
        try s.database.write { db in
            for i in 0..<100 {
                try ProjectFile(id: "f\(i)", projectID: p.id, displayName: "f\(i).md", size: 10, origin: .copied,
                                indexState: .ready, progress: 1, createdAt: Date()).insert(db)
            }
        }
        #expect(try s.admit(p.id, sizes: [1]) == 0)  // file #101
        let q = try s.create(name: "Big")
        let gb = ProjectStore.maxBytes
        #expect(try s.admit(q.id, sizes: [gb]) == 1)  // exactly 2 GB fits
        #expect(try s.admit(q.id, sizes: [gb - 10, 11]) == 1)  // 2 GB + 1 byte does not
        // A sparse 2.1 GB file reports its logical size (what the limit counts), without writing 2 GB.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(2.1 * 1024 * 1024 * 1024))
        try h.close()
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        #expect(try s.admit(q.id, sizes: [size]) == 0)
    }

    @Test func instructionsFreezeAtFirstSendAndMoveKeepsThem() throws {
        let s = try store()
        let p = try s.create(name: "Dutch")
        try s.setInstructions(p.id, "Always answer in formal Dutch.")
        let inside = try chat(s, "in", project: p.id)
        let outside = try chat(s, "out")
        #expect(try s.frozenInstructions(chatID: inside) == "Always answer in formal Dutch.")
        #expect(try s.frozenInstructions(chatID: outside) == "")
        try s.setInstructions(p.id, "Answer in English.")
        #expect(try s.frozenInstructions(chatID: inside) == "Always answer in formal Dutch.")  // existing chat: unchanged
        try s.move(chatID: outside, to: p.id)
        #expect(try s.frozenInstructions(chatID: outside) == "")  // moved: its prefix is unchanged
        let fresh = try chat(s, "new", project: p.id)
        #expect(try s.frozenInstructions(chatID: fresh) == "Answer in English.")
        try s.move(chatID: inside, to: nil)
        #expect(try s.chatIDs(p.id).sorted() == [fresh, outside].sorted())
        try s.setInstructions(p.id, String(repeating: "x", count: 9_000))
        #expect(try s.instructions(p.id).count == Project.maxInstructions)
    }

    @Test func deleteKeepOrDeleteChatsAndRefcountedBlobs() throws {
        let s = try store()
        let keep = try s.create(name: "Keep")
        let gone = try s.create(name: "Gone")
        let k1 = try chat(s, "k1", project: keep.id), k2 = try chat(s, "k2", project: keep.id)
        let g1 = try chat(s, "zebracorn notes", project: gone.id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared.md"), own = dir.appendingPathComponent("own.md")
        try Data("a".utf8).write(to: shared)
        try Data("b".utf8).write(to: own)
        try s.database.write { db in
            try FileBlobRecord(id: "b-shared", sha256: String(repeating: "a", count: 64), size: 1, path: shared.path, origin: .upload).insert(db)
            try FileBlobRecord(id: "b-own", sha256: String(repeating: "b", count: 64), size: 1, path: own.path, origin: .upload).insert(db)
            try AttachmentRecord(messageID: nil, blobID: "b-shared", displayName: "shared.md", uti: "net.daringfireball.markdown").insert(db)
            for (id, blob) in [("pf1", "b-shared"), ("pf2", "b-own")] {
                try ProjectFile(id: id, projectID: gone.id, blobID: blob, displayName: "\(id).md", size: 1, origin: .copied,
                                indexState: .ready, progress: 1, createdAt: Date()).insert(db)
                try db.execute(sql: "INSERT INTO chunk (source, source_id, ord, text, created_at) VALUES ('project_file', ?, 0, 'text', 0)", arguments: [id])
            }
            try db.execute(sql: "INSERT INTO memory_topic (id, scope, project_id, name, created_at, updated_at) VALUES ('t', 'project', ?, 'Work', 0, 0)", arguments: [gone.id])
            try db.execute(sql: "INSERT INTO memory_item (id, topic_id, scope, project_id, key, text, origin, created_at, updated_at) VALUES ('i', 't', 'project', ?, 'k', 'Uses LaTeX', 'user', 0, 0)", arguments: [gone.id])
        }
        try s.delete(keep.id, keepChats: true)
        let kept = try s.database.read { try String.fetchAll($0, sql: "SELECT id FROM chat WHERE id IN (?, ?) AND project_id IS NULL", arguments: [k1, k2]) }
        #expect(kept.count == 2)
        try s.delete(gone.id, keepChats: false)
        try s.database.read { (db: Database) throws -> Void in
            #expect(try ChatRecord.fetchOne(db, key: g1) == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_fts WHERE chat_fts MATCH 'zebracorn'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk WHERE source = 'project_file'") == 0)
            #expect(try FileBlobRecord.fetchOne(db, key: "b-shared") != nil)  // an attachment still uses it
            #expect(try FileBlobRecord.fetchOne(db, key: "b-own") == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_item") == 0)  // project memory cascaded
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") == 0)
        }
        #expect(FileManager.default.fileExists(atPath: shared.path) && !FileManager.default.fileExists(atPath: own.path))
    }

    /// RC review P2-4: a recording sharing a project file's blob (same sha) does not make removing the file or deleting
    /// the project throw on RESTRICT, and the blob and its file stay for the recording.
    @Test func deleteKeepsABlobARecordingStillUses() throws {
        let s = try store()
        let p = try s.create(name: "Voice")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("a.m4a")
        try Data("a".utf8).write(to: audio)
        try s.database.write { db in
            try FileBlobRecord(id: "b-rec", sha256: String(repeating: "c", count: 64), size: 1, path: audio.path, origin: .recording).insert(db)
            try RecordingRecord(chatID: nil, createdAt: Date(), durationMs: 1, transcript: "t", fileBlobID: "b-rec", language: "en",
                                engine: "parakeet").insert(db)
            for id in ["pf1", "pf2"] {
                try ProjectFile(id: id, projectID: p.id, blobID: "b-rec", displayName: "\(id).m4a", size: 1, origin: .copied,
                                indexState: .ready, progress: 1, createdAt: Date()).insert(db)
            }
        }
        try s.removeFile("pf1")
        try s.delete(p.id, keepChats: true)
        try s.database.read { (db: Database) throws -> Void in
            #expect(try FileBlobRecord.fetchOne(db, key: "b-rec") != nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") == 0)
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func projectOnlyMemoryDefaultsToGlobal() throws {
        let s = try store()
        let p = try s.create(name: "Lab")
        let c = try chat(s, "x", project: p.id)
        #expect(try s.memoryScope(chatID: c)?.mode == .global)
        try s.setMemoryMode(p.id, .project)
        #expect(try s.memoryScope(chatID: c).map { $0.projectID == p.id && $0.mode == .project } == true)
        #expect(try s.memoryScope(chatID: try chat(s, "y")) == nil)
    }
}
