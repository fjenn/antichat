// `runtime_install` (M6.T16 step 3; migration `v28_runtime_install`): one row per installed runtime component —
// File tools now, the video runtime in M5.T01 (D-026, generic). `id` is the runtime name; the folder is
// `Runtimes/<id>@<version>/`; `sha256` is the verified zip's (the catalog entry it came from).
import Foundation
import GRDB

public struct RuntimeInstallRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "runtime_install"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var id: String
    public var version: String
    public var path: String
    public var sha256: String
    public var sizeBytes: Int64
    public var installedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, version, path, sha256
        case sizeBytes = "size_bytes", installedAt = "installed_at"
    }

    public init(id: String, version: String, path: String, sha256: String, sizeBytes: Int64, installedAt: Date = Date()) {
        self.id = id; self.version = version; self.path = path; self.sha256 = sha256; self.sizeBytes = sizeBytes
        self.installedAt = installedAt
    }
}
