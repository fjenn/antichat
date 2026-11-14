// `hardware_profile` (architecture §5.1: os_build, chip, gpu_cores, ram, W, B, tier, speed_class, probed_at;
// P-platform-01), migration `v5_hardware_profile` (M2.T01). One row (id = 1). Storage does not know the Platform
// type: `profileJSON` is the encoded `HardwareProfile`, the other columns mirror it for Diagnostics queries.
import Foundation
import GRDB

public struct HardwareProfileRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hardware_profile"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: Int = 1
    public var osBuild: String
    public var chip: String
    public var gpuCores: Int?
    public var ram: Int
    public var w: Double?
    public var b: Double
    public var tier: String
    public var speedClass: String
    public var probedAt: Date
    public var profileJSON: String
    enum CodingKeys: String, CodingKey {
        case id, chip, ram, w, b, tier
        case osBuild = "os_build", gpuCores = "gpu_cores", speedClass = "speed_class", probedAt = "probed_at"
        case profileJSON = "profile_json"
    }

    public init(osBuild: String, chip: String, gpuCores: Int?, ram: Int, w: Double?, b: Double, tier: String,
                speedClass: String, probedAt: Date, profileJSON: String) {
        self.osBuild = osBuild; self.chip = chip; self.gpuCores = gpuCores; self.ram = ram; self.w = w; self.b = b
        self.tier = tier; self.speedClass = speedClass; self.probedAt = probedAt; self.profileJSON = profileJSON
    }

    /// The cached row, if any.
    public static func load(_ database: AppDatabase) throws -> HardwareProfileRecord? {
        try database.read { try HardwareProfileRecord.fetchOne($0, key: 1) }
    }

    /// Replaces the cached row.
    public func save(_ database: AppDatabase) throws {
        try database.write { try self.save($0) }
    }
}
