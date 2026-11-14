// Ported from mhayes853/sqlite-vec-data@f980c99:Sources/SQLiteVecData/Database+LoadSQLiteVec.swift (MIT; P-media-15):
// register the statically linked sqlite-vec on each connection in `Configuration.prepareDatabase` with
// `sqlite3_vec_init(db.sqliteConnection, nil, nil)`. sqlite-vec is compiled with SQLITE_CORE, so it calls the system
// SQLite directly and no extension loading is involved (M2.T16 step 1).
import Foundation
import GRDB
import SQLiteVec

public enum VecLoader {
    /// The version the vendored amalgamation reports (`SELECT vec_version()`; launch self-test, M2.T16 DoD).
    public static let expectedVersion = "v0.1.9"
    /// Embedding width of `chunk_vec` (Qwen3-Embedding-0.6B, architecture §5.1).
    public static let dimensions = 1024

    /// Registers vec0 + the vec_* functions on `db`. Called for every connection (pool readers included).
    public static func load(_ db: Database) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_vec_init(db.sqliteConnection, &err, nil)
        if rc != 0 {  // SQLITE_OK
            let msg = err.map { String(cString: $0) } ?? "rc \(rc)"
            throw DatabaseError(message: "sqlite-vec init failed: \(msg)")
        }
    }

    /// `vec_version()` on `db`, or nil when sqlite-vec is not registered.
    public static func version(_ db: Database) -> String? {
        try? String.fetchOne(db, sql: "SELECT vec_version()")
    }

    /// Launch self-test (M2.T16 DoD): sqlite-vec is registered and is the vendored version.
    public static func selfTest(_ database: AppDatabase) -> Bool {
        (try? database.read { version($0) }) == expectedVersion
    }
}
