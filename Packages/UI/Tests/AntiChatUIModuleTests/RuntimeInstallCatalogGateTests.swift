// RC review P2-9: a File tools runtime install fails closed on the catalog exactly like a model install
// (`InstallQueue` → `catalogRefused`): an expired catalog, a bad-signature latch or no catalog store starts nothing
// and shows `catalog.badSignature`. The store is the bundled signed baseline, verified under the production keys it is
// signed with (Config/Keys.release.plist; a test-keys build pins only the test keys); nothing is fetched.
//   make test-unit FILTER=RuntimeInstallCatalogGateTests
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct RuntimeInstallCatalogGateTests {
    /// Catalog keys A and B from Config/Keys.release.plist (the source of `PinnedKeys` in release-keys builds).
    static let releaseKeys: [String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Config/Keys.release.plist")
            .standardizedFileURL
        let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)) as? [String: Any]
        return ["CatalogPublicKeyA", "CatalogPublicKeyB"].compactMap { plist?[$0] as? String }
    }()

    static func store(now: Date) -> (CatalogStore, URL) {
        let cache = FileManager.default.temporaryDirectory.appending(path: "rt-gate-\(UUID().uuidString)")
        let store = CatalogStore(url: URL(string: "http://127.0.0.1:9/catalog/v2/catalog.json")!, cacheDirectory: cache,
                                 database: nil, verifier: CatalogVerifier(base64Keys: releaseKeys), now: { now },
                                 fetch: { _ in throw URLError(.notConnectedToInternet) })
        return (store, cache)
    }

    @Test func expiredCatalogStartsNoRuntimeInstall() throws {
        let (store, cache) = Self.store(now: Date.distantFuture)
        defer { try? FileManager.default.removeItem(at: cache) }
        #expect(!store.mayInstallNew)
        let m = FileToolsSettingsModel(database: try AppDatabase.inMemory(), catalogStore: store)
        #expect(m.runtime?.name == "filetools-runtime", "the baseline lists the runtime, so the button is enabled")
        m.install()
        #expect(m.progress == nil, "no download started")
        #expect(m.errorKey == "catalog.badSignature")
        #expect(m.installed == nil)
    }

    @Test func refusalFollowsTheStoreAndNoStoreRefuses() throws {
        let (store, cache) = Self.store(now: Date(timeIntervalSince1970: 1_800_000_000))  // 2027-01-15, before expiry
        defer { try? FileManager.default.removeItem(at: cache) }
        let m = FileToolsSettingsModel(database: try AppDatabase.inMemory(), catalogStore: store)
        #expect(store.mayInstallNew && m.mayInstallNew(), "a verified, unexpired catalog allows the install")
        let none = FileToolsSettingsModel(database: try AppDatabase.inMemory(), catalogStore: nil)
        #expect(!none.mayInstallNew())
        // A bad-signature latch (or any refusal) stops it before anything starts.
        m.mayInstallNew = { false }
        m.install()
        #expect(m.progress == nil && m.errorKey == "catalog.badSignature")
    }
}
