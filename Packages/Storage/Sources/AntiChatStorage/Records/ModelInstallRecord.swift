// `model_install` + `model_override` (architecture §5.1; M2.T06, migration `v8_model_install`). One install row per
// slot (`<pack>/<mode>/<role>`); overrides are `{pack, mode, model_id}` and survive catalog updates (E.2.3 step 5).
// Storage does not know the Platform types: packs, modes and states are their raw strings.
import Foundation
import GRDB

public struct ModelInstallRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_install"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var slot: String
    public var catalogEntryID: String
    public var manifestSHA: String
    public var state: String
    public var previousManifestSHA: String?
    public var installedAt: Date?
    enum CodingKeys: String, CodingKey {
        case slot, state
        case catalogEntryID = "catalog_entry_id", manifestSHA = "manifest_sha", previousManifestSHA = "previous_manifest_sha"
        case installedAt = "installed_at"
    }

    public init(slot: String, catalogEntryID: String, manifestSHA: String, state: String, previousManifestSHA: String? = nil,
                installedAt: Date? = nil) {
        self.slot = slot; self.catalogEntryID = catalogEntryID; self.manifestSHA = manifestSHA; self.state = state
        self.previousManifestSHA = previousManifestSHA; self.installedAt = installedAt
    }
}

public struct ModelOverrideRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_override"
    public var pack: String
    public var mode: String
    public var modelID: String
    enum CodingKeys: String, CodingKey { case pack, mode, modelID = "model_id" }

    public init(pack: String, mode: String, modelID: String) { self.pack = pack; self.mode = mode; self.modelID = modelID }

    public static func all(_ database: AppDatabase) throws -> [ModelOverrideRecord] {
        try database.read { try ModelOverrideRecord.order(Column("pack"), Column("mode")).fetchAll($0) }
    }

    public func save(_ database: AppDatabase) throws { try database.write { try self.save($0) } }
}
