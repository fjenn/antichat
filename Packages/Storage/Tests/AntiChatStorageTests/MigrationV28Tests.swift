// M6.T16 step 3: v28_runtime_install (was v16_ on m6/sandbox) adds `runtime_install` to a database written at v27 (rows kept) and the
// record round-trips (one row per runtime name; a re-install replaces it).
//   make test-unit FILTER=MigrationV28Tests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct MigrationV28Tests {
    @Test func upgradesAV27DatabaseAndRoundTripsARow() throws {
        var config = Configuration()
        config.prepareDatabase { try VecLoader.load($0) }
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { try ChunkTables.ensureVectorTable($0) }
        try Migrations.migrator().migrate(queue, upTo: "v27_message_fts_backlog")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES ('b1', 'abc', 3, '/x', 0, 'upload')")
        }
        let before = try queue.read { db in try db.tableExists("runtime_install") }
        #expect(before == false)
        try Migrations.migrator().migrate(queue)
        let (exists, blobs) = try queue.read { db in
            (try db.tableExists("runtime_install"), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_blob"))
        }
        #expect(exists && blobs == 1)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            try RuntimeInstallRecord(id: "filetools-runtime", version: "0.1.0", path: "/p/filetools-runtime@0.1.0",
                                     sha256: String(repeating: "a", count: 64), sizeBytes: 42, installedAt: at).save(db)
            try RuntimeInstallRecord(id: "filetools-runtime", version: "0.1.1", path: "/p/filetools-runtime@0.1.1",
                                     sha256: String(repeating: "b", count: 64), sizeBytes: 43, installedAt: at).save(db)
        }
        let rows = try queue.read { try RuntimeInstallRecord.fetchAll($0) }
        #expect(rows.count == 1 && rows[0].version == "0.1.1" && rows[0].sizeBytes == 43 && rows[0].installedAt == at)
    }
}

extension MigrationV28Tests {
    /// A dev container from m6/sandbox recorded `v16_runtime_install`: it is not newer data and the body is not re-run.
    @Test func aDatabaseThatRanTheOldIdIsNotMigratedTwice() throws {
        #expect(Migrations.unknownIdentifiers(in: ["v16_runtime_install"]).isEmpty)
        var config = Configuration()
        config.prepareDatabase { try VecLoader.load($0) }
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { try ChunkTables.ensureVectorTable($0) }
        try Migrations.migrator().migrate(queue, upTo: "v27_message_fts_backlog")
        try queue.write { db in
            try Migrations.v28RuntimeInstall(db)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v16_runtime_install')")
        }
        try Migrations.migrator().migrate(queue)  // would fail with "table runtime_install already exists" if re-run
        let ids = try queue.read { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(ids.contains("v28_runtime_install"))
    }
}
