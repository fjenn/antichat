// `network_activity` (architecture §5.1: ts, category, host, bytes, outcome; rolling 7 days; never written for
// incognito, P-platform-08), migration `v6_network_activity` (M2.T02). Written by AntiChatPlatform's
// NetworkActivityStore from the gate's events; read by Settings → Privacy & Data → Network activity (M2.T03).
import Foundation
import GRDB

public struct NetworkActivityRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_activity"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: Int64?
    public var ts: Date
    public var category: String
    public var host: String
    public var bytes: Int64
    public var outcome: String

    public init(id: Int64? = nil, ts: Date, category: String, host: String, bytes: Int64, outcome: String) {
        self.id = id; self.ts = ts; self.category = category; self.host = host; self.bytes = bytes; self.outcome = outcome
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Rows newer than `since`, newest first.
    public static func recent(_ database: AppDatabase, since: Date) throws -> [NetworkActivityRecord] {
        try database.read {
            try NetworkActivityRecord.filter(Column("ts") >= since.timeIntervalSince1970).order(Column("ts").desc).fetchAll($0)
        }
    }

    /// Deletes rows older than `before` (the rolling 7-day window).
    @discardableResult
    public static func prune(_ database: AppDatabase, before: Date) throws -> Int {
        try database.write { try NetworkActivityRecord.filter(Column("ts") < before.timeIntervalSince1970).deleteAll($0) }
    }
}
