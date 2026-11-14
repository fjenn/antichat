// `consent` (M2.T17, R-211; migration `v10_consent`): one row per accepted version of the Evil terms. The version is
// a hash of the exact copy shown (EvilTerms.version in Harness), so changed terms are asked for again.
import Foundation
import GRDB

public struct ConsentRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "consent"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public var kind: String
    public var version: String
    public var acceptedAt: Date
    public var adultSelfDeclared: Bool
    enum CodingKeys: String, CodingKey {
        case kind, version
        case acceptedAt = "accepted_at", adultSelfDeclared = "adult_self_declared"
    }

    public init(kind: String, version: String, acceptedAt: Date = Date(), adultSelfDeclared: Bool) {
        self.kind = kind; self.version = version; self.acceptedAt = acceptedAt; self.adultSelfDeclared = adultSelfDeclared
    }
}
