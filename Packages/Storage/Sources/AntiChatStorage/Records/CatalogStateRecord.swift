// `catalog_state` (architecture §5.1; M2.T05, migration `v7_catalog_state`): the highest catalog_version ever
// accepted (rollback protection, NFR-SEC7), where the last good catalog is cached, when it was fetched and when it
// expires, and the last refresh outcome (`ok`, `expired`, `badSignature`, `rollback`, `schema`, `network`).
import Foundation
import GRDB

public struct CatalogStateRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "catalog_state"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: Int = 1
    public var highWater: Int
    public var lastGoodPath: String?
    public var fetchedAt: Date?
    public var expiresAt: Date?
    public var status: String
    enum CodingKeys: String, CodingKey {
        case id, status
        case highWater = "high_water", lastGoodPath = "last_good_path", fetchedAt = "fetched_at", expiresAt = "expires_at"
    }

    public init(highWater: Int, lastGoodPath: String?, fetchedAt: Date?, expiresAt: Date?, status: String) {
        self.highWater = highWater; self.lastGoodPath = lastGoodPath; self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt; self.status = status
    }

    public static func load(_ database: AppDatabase) throws -> CatalogStateRecord? {
        try database.read { try CatalogStateRecord.fetchOne($0, key: 1) }
    }

    public func save(_ database: AppDatabase) throws {
        try database.write { try self.save($0) }
    }
}
