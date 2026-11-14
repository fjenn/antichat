// M2.T17 step 1 (R-211 AC1–AC3): the Evil terms consent. `EvilTerms.version` is the sha256 prefix of the exact
// copy the user saw (`onb.3.body` + `onb.3.adult`); a row is stored with the date and that version. If the copy
// changes, the version changes, no row matches, and the enable sheet is shown again. The consent is a
// self-declaration of adulthood and responsibility (D-005); nothing else is checked.
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public enum EvilTerms {
    public static let kind = "evil_terms"

    /// sha256(body + "\n" + adult), first 16 hex digits.
    public static func version(body: String, adult: String) -> String {
        let d = SHA256.hash(data: Data((body + "\n" + adult).utf8))
        return d.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

public struct ConsentStore: Sendable {
    public let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    /// Stores acceptance of `version` (only with the adult self-declaration ticked).
    public func accept(version: String, adultSelfDeclared: Bool, at date: Date = Date()) throws {
        guard adultSelfDeclared else { throw ConsentError.adultDeclarationMissing }
        try database.write { db in
            try ConsentRecord(kind: EvilTerms.kind, version: version, acceptedAt: date, adultSelfDeclared: true).save(db)
        }
    }

    public func hasAccepted(version: String) -> Bool {
        (try? database.read { db in
            try ConsentRecord.filter(Column("kind") == EvilTerms.kind && Column("version") == version
                                     && Column("adult_self_declared") == true).fetchCount(db)
        }) ?? 0 > 0
    }

    public func record(version: String) -> ConsentRecord? {
        try? database.read { db in
            try ConsentRecord.filter(Column("kind") == EvilTerms.kind && Column("version") == version).fetchOne(db)
        }
    }

    public enum ConsentError: Error, Equatable { case adultDeclarationMissing }
}
