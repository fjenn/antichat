// M2.T05/T06 test support: fixture catalogs (fixtures/catalog, signed with test key A) served by an in-memory
// fetcher, a fixed clock inside the valid fixture's window, and a throwaway cache directory.
@testable import AntiChatPlatform
import AntiChatStorage
import CryptoKit
import Foundation
import Testing

enum CatalogFixtures {
    static let root: URL = HardwareProbe.fixtureURL("t0-m1-8")!.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "catalog")
    static let url = URL(string: "https://catalog.test/catalog/v2/catalog.json")!
    /// Inside catalog-valid's window (issued 2026-11-01, expires 2027-01-30).
    static let now = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!

    static func data(_ name: String) throws -> Data { try Data(contentsOf: root.appending(path: name)) }
    static func pair(_ name: String) throws -> (Data, Data) { (try data("\(name).json"), try data("\(name).json.sig")) }
    static func catalog(_ name: String) throws -> ModelCatalog { try ModelCatalog.decode(data("\(name).json")) }

    static func key(_ name: String) throws -> Curve25519.Signing.PrivateKey {
        let s = String(decoding: try data("test-keys/\(name).priv"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: s)!)
    }

    static func sig(_ data: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data(try key.signature(for: data).base64EncodedString().utf8)
    }

    /// The shipped baseline's bytes re-signed with test key A. Since release/1 the bundled baseline is signed with the
    /// production key A (`Config/Keys.release.plist`), which a test-keys build does not pin; stores built on the test
    /// verifier take this copy so their baseline fallback stays verified, never skipped.
    static func testSignedBaseline() throws -> (data: Data, sig: Data) {
        let b = try #require(CatalogStore.bundledBaseline())
        return (b.data, try sig(b.data, key: key("catalog-a")))
    }

    /// The production catalog keys A and B, read from `Config/Keys.release.plist` (the source `PinnedKeys` is generated
    /// from), for checking what ships regardless of the keys this build pins.
    static func releaseKeys() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Config/Keys.release.plist")
            .standardizedFileURL
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        return try ["CatalogPublicKeyA", "CatalogPublicKeyB"].map { try #require(plist[$0] as? String) }
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "antichat-catalog-\(UUID().uuidString)")
    }
}

/// Serves whatever pair is current; `fail` makes the next fetches throw (offline / network down).
final class FixtureServer: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (Data, Data)?
    private var error: (any Error)?
    private(set) var requests = 0

    func serve(_ pair: (Data, Data)) { lock.withLock { current = pair; error = nil } }
    func fail(_ e: any Error = URLError(.notConnectedToInternet)) { lock.withLock { error = e } }

    var fetch: CatalogStore.Fetch {
        { [self] url in
            try lock.withLock {
                requests += 1
                if let error { throw error }
                guard let c = current else { throw URLError(.fileDoesNotExist) }
                return url.path.hasSuffix(".sig") ? c.1 : c.0
            }
        }
    }
}

extension CatalogStore {
    static func fixture(server: FixtureServer, cache: URL, database: AppDatabase? = nil, verifier: CatalogVerifier = CatalogVerifier(),
                        baseline: (data: Data, sig: Data)? = try? CatalogFixtures.testSignedBaseline(),
                        now: Date = CatalogFixtures.now) -> CatalogStore {
        CatalogStore(url: CatalogFixtures.url, cacheDirectory: cache, database: database, verifier: verifier, baseline: baseline,
                     now: { now }, fetch: server.fetch)
    }
}
