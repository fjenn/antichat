// M5.T08: v32_video_run_history (v31 before the M5 merge renumber) adds `video_run_history` to a database written at v28 (rows kept) and takes a row
// with the columns the estimator's history reads (VideoHistoryStore, Harness).
//   make test-unit FILTER=MigrationV32VideoRunHistoryTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct MigrationV32VideoRunHistoryTests {
    @Test func upgradesAV28DatabaseAndTakesARow() throws {
        var config = Configuration()
        config.prepareDatabase { try VecLoader.load($0) }
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { try ChunkTables.ensureVectorTable($0) }
        try Migrations.migrator().migrate(queue, upTo: "v28_runtime_install")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES ('b1', 'abc', 3, '/x', 0, 'upload')")
        }
        #expect(try queue.read { try $0.tableExists("video_run_history") } == false)
        try Migrations.migrator().migrate(queue)
        let (columns, blobs) = try queue.read { db in
            (try db.columns(in: "video_run_history").map(\.name), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_blob"))
        }
        #expect(columns == ["id", "preset_key", "speed_class", "estimated_s", "actual_s", "created_at"])
        #expect(blobs == 1)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO video_run_history (id, preset_key, speed_class, estimated_s, actual_s, created_at)
                VALUES ('r1', 't2v-480p-short', 'S4', 11.96, 12.4, 1800000000)
                """)
        }
        let actual = try queue.read { try Double.fetchOne($0, sql: "SELECT actual_s FROM video_run_history WHERE preset_key = 't2v-480p-short'") }
        #expect(actual == 12.4)
        #expect(Migrations.identifiers.contains("v32_video_run_history"))  // head moved on (v33_library_fts, M5.T13)
    }
}
