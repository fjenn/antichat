// M3.T03 (AT-050 AC4; R-050): v21_voice_recording (v15 before the merge renumber) upgrades a v20 file (file_blob rebuilt with its rows and the
// attachment references intact, `recording` accepted as an origin, pre-migration backup) and RecordingStore keeps the
// newest 20 recordings, deleting older rows with their files; an incognito (in-memory) store writes nothing at all.
//   make test-unit FILTER=RecordingStoreTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct RecordingStoreTests {
    static func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A fake `.m4a` (unique bytes) where the helper would have written it.
    static func audio(_ dir: URL, _ i: Int) throws -> URL {
        let u = dir.appendingPathComponent("incoming-\(i).m4a")
        try Data("audio \(i) \(UUID().uuidString)".utf8).write(to: u)
        return u
    }

    /// Every file under `dir` (recursive), relative paths.
    static func tree(_ dir: URL) -> Set<String> {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: Set<String> = []
        while let u = e?.nextObject() as? URL { out.insert(u.path.replacingOccurrences(of: dir.path, with: "")) }
        return out
    }

    @Test func keepsTheNewest20AndDeletesTheOlderFiles() throws {
        let dir = try Self.tempDir("rec")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(database: try AppDatabase.onDisk(at: dir.appendingPathComponent("db/antichat.sqlite")), mediaRoot: dir.appendingPathComponent("Media"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var paths: [String] = []
        for i in 0..<22 {
            let r = try #require(try store.add(audio: try Self.audio(dir, i), transcript: "t\(i)", language: "en", engine: "parakeet",
                                               durationMs: 1_000 + i, chatID: nil, now: t0.addingTimeInterval(Double(i))))
            paths.append(try #require(try store.fileURL(r)).path)
        }
        let all = try store.all()
        #expect(all.count == 20)
        #expect(all.first?.transcript == "t21" && all.last?.transcript == "t2", "newest first; t0 and t1 dropped")
        #expect(!FileManager.default.fileExists(atPath: paths[0]) && !FileManager.default.fileExists(atPath: paths[1]))
        #expect(paths[2...].allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(paths.allSatisfy { $0.contains("/Media/2027/") && $0.hasSuffix(".m4a") }, "Media/<yyyy>/<sha256>.m4a")
        let blobs = try store.database.read { try FileBlobRecord.filter(Column("origin") == "recording").fetchCount($0) }
        #expect(blobs == 20)
        try store.delete(id: all[0].id)
        #expect(try store.all().count == 19)
        #expect(!FileManager.default.fileExists(atPath: paths[21]))
    }

    /// RC review P2-4: a project file sharing the recording's blob (same sha) keeps its file when the recording goes.
    @Test func deletingARecordingKeepsABlobAProjectFileStillUses() throws {
        let dir = try Self.tempDir("rec-pf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(database: try AppDatabase.onDisk(at: dir.appendingPathComponent("db/antichat.sqlite")), mediaRoot: dir.appendingPathComponent("Media"))
        let r = try #require(try store.add(audio: try Self.audio(dir, 0), transcript: "t", language: "en", engine: "parakeet",
                                           durationMs: 1, chatID: nil))
        let path = try #require(try store.fileURL(r)).path
        try store.database.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, created_at, updated_at) VALUES ('p', 'P', 0, 0)")
            try db.execute(sql: "INSERT INTO project_file (id, project_id, blob_id, display_name, origin, created_at) VALUES ('pf', 'p', ?, 'a.m4a', 'copied', 0)",
                           arguments: [r.fileBlobID])
        }
        try store.delete(id: r.id)
        #expect(try store.all().isEmpty)
        try store.database.read { (db: Database) throws -> Void in
            #expect(try FileBlobRecord.fetchOne(db, key: r.fileBlobID) != nil)
            #expect(try String.fetchOne(db, sql: "SELECT blob_id FROM project_file WHERE id = 'pf'") == r.fileBlobID)
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func incognitoWritesNoRowAndNoFile() throws {
        let dir = try Self.tempDir("rec-inc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let before = Self.tree(dir)
        let incoming = try Self.audio(dir, 0)
        let store = RecordingStore(database: try AppDatabase.inMemory(), mediaRoot: media)
        #expect(try store.add(audio: incoming, transcript: "secret", language: "en", engine: "parakeet", durationMs: 1, chatID: nil) == nil)
        #expect(try store.all().isEmpty)
        #expect(Self.tree(dir) == before, "nothing new on disk (the incoming audio is removed too)")
    }

    @Test func v21RebuildsFileBlobKeepingRowsAndReferences() throws {
        let dir = try Self.tempDir("v15")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        do {
            var config = Configuration()
            config.prepareDatabase { try VecLoader.load($0) }
            let pool = try DatabasePool(path: url.path, configuration: config)
            try pool.write { try ChunkTables.ensureVectorTable($0) }
            try Migrations.migrator().migrate(pool, upTo: "v20_projects")
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES ('b1', 'abc', 3, '/x', 0, 'upload');
                    INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at)
                      VALUES ('a1', NULL, 'b1', 'x.txt', 'public.plain-text', 0);
                    """)
            }
        }
        let db = try AppDatabase.onDisk(at: url)
        try db.read { d in
            #expect(try FileBlobRecord.fetchOne(d, key: "b1")?.origin == .upload)
            #expect(try AttachmentRecord.fetchOne(d, key: "a1")?.blobID == "b1")
            #expect(try Row.fetchAll(d, sql: "PRAGMA foreign_key_check").isEmpty)
            let fks = try Row.fetchAll(d, sql: "PRAGMA foreign_key_list(attachment)").map { $0["table"] as String }
            #expect(fks.contains("file_blob"))
        }
        try db.write { d in
            try FileBlobRecord(id: "b2", sha256: "def", size: 1, path: "/y", origin: .recording).insert(d)
            // RESTRICT still guards a referenced blob after the rebuild.
            #expect(throws: (any Error).self) { try d.execute(sql: "DELETE FROM file_blob WHERE id = 'b1'") }
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-\(Migrations.head)-") }, "\(backups)")
    }
}
