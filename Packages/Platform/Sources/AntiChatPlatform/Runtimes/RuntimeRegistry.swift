// M6.T16 step 3: where installs are recorded — the `runtime_install` table (v28_runtime_install). Generic: one row
// per runtime name (File tools now, video runtime in M5.T01, D-026).
import AntiChatStorage
import Foundation
import GRDB

public struct RuntimeRegistry: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func record(_ name: String) -> RuntimeInstallRecord? {
        try? database.read { db in try RuntimeInstallRecord.fetchOne(db, key: name) }
    }

    public func all() -> [RuntimeInstallRecord] {
        (try? database.read { db in try RuntimeInstallRecord.order(Column("id")).fetchAll(db) }) ?? []
    }

    public func save(_ r: RuntimeInstallRecord) throws {
        try database.write { db in try r.save(db) }
    }

    public func delete(_ name: String) throws {
        _ = try database.write { db in try RuntimeInstallRecord.deleteOne(db, key: name) }
    }
}
