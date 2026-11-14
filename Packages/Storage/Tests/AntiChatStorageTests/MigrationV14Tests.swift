// M6.T01 step 1: v14_files_m6 upgrades a database written at v13 (rows kept, new attachment columns default to
// `extract_state = none`, `retrieval` + `chunk.page_ref` + `artifact_version.parent_version_id` exist), and an on-disk
// upgrade first copies the file to `Backups/pre-v14_files_m6-<yyyyMMdd>.sqlite`.
//   make test-unit FILTER=MigrationV14Tests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct MigrationV14Tests {
    @Test func upgradesAV13FileAndBacksItUpFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        do {
            var config = Configuration()
            config.prepareDatabase { try VecLoader.load($0) }
            let pool = try DatabasePool(path: url.path, configuration: config)
            try pool.write { try ChunkTables.ensureVectorTable($0) }
            try Migrations.migrator().migrate(pool, upTo: "v13_artifact")
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
            let a = try #require(try AttachmentRecord.fetchOne(d, key: "a1"))
            #expect(a.extractState == .none && a.tokenCount == nil && a.pageMapJSON == nil && a.ocrText == nil)
            #expect(try d.tableExists("retrieval"))
            #expect(try d.columns(in: "chunk").contains { $0.name == "page_ref" })
            #expect(try d.columns(in: "artifact_version").contains { $0.name == "parent_version_id" })
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)
        #expect(backups.count == 1 && backups[0].hasPrefix("pre-\(Migrations.head)-"), "\(backups)")  // M8.T01: named after the head
        let copy = try DatabaseQueue(path: dir.appendingPathComponent("Backups/\(backups[0])").path)
        #expect(try copy.read { try Migrations.migrator().appliedIdentifiers($0) }.contains("v14_files_m6") == false)
        #expect(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment") } == 1)
        // A fresh file gets no backup.
        let fresh = dir.appendingPathComponent("fresh/antichat.sqlite")
        _ = try AppDatabase.onDisk(at: fresh)
        #expect(!FileManager.default.fileExists(atPath: fresh.deletingLastPathComponent().appendingPathComponent("Backups").path))
    }

    @Test func versionsChainToTheirParent() throws {
        let db = try AppDatabase.inMemory()
        try db.write { d in
            try ChatRecord(id: "c1", mode: .normal).insert(d)
            try FileBlobRecord(id: "b1", sha256: "s1", size: 1, path: "/1", createdAt: Date(), origin: .generated).insert(d)
        }
        let repo = ArtifactRepository(db)
        let art = try repo.create(chatID: "c1", kind: "pdf", title: "t")
        let v1 = try repo.addVersion(artifactID: art.id, blobID: "b1")
        let v2 = try repo.addVersion(artifactID: art.id, blobID: "b1")
        #expect(v1.parentVersionID == nil)
        #expect(v2.parentVersionID == v1.id && v2.n == 2)
    }
}
