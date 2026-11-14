// M2.T16 step 1–2: sqlite-vec is registered on every connection (pool readers too), reports the vendored version,
// and `chunk_vec` answers a KNN query; deleting a chunk drops its vector.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("VecLoaderTests") struct VecLoaderTests {
    @Test func versionInMemoryAndOnDisk() throws {
        let mem = try AppDatabase.inMemory()
        #expect(VecLoader.selfTest(mem))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-vec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        #expect(try disk.read { VecLoader.version($0) } == "v0.1.9")
        #expect(try disk.write { VecLoader.version($0) } == "v0.1.9")
    }

    @Test func knnAndCascade() throws {
        let db = try AppDatabase.inMemory()
        try db.write { db in
            for i in 0..<3 {
                try db.execute(sql: "INSERT INTO chunk(source, source_id, ord, text, created_at) VALUES ('t', ?, 0, ?, 0)",
                               arguments: ["s\(i)", "text \(i)"])
                var v = [Float](repeating: 0, count: VecLoader.dimensions)
                v[i] = 1
                try db.execute(sql: "INSERT INTO chunk_vec(rowid, embedding) VALUES (?, ?)",
                               arguments: [db.lastInsertedRowID, ChunkTables.blob(v)])
            }
            var q = [Float](repeating: 0, count: VecLoader.dimensions)
            q[1] = 0.9; q[2] = 0.1
            let ids = try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunk_vec WHERE embedding MATCH ? AND k = 2 ORDER BY distance
                """, arguments: [ChunkTables.blob(q)])
            #expect(ids == [2, 3])
            try db.execute(sql: "DELETE FROM chunk WHERE id = 2")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_vec") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_fts WHERE chunk_fts MATCH 'text'") == 2)
        }
    }
}
