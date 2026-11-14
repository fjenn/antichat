// M2.T05 AT-220 part 2 (R-220 AC1, AC4) + AT-NFR-SEC7: signed catalog accepted; bad signature → rejected, last good
// kept, `catalog.badSignature`, nothing new installs; rollback → rejected; expired → accepted with a warning and
// `mayInstallNew == false`; `disable` revocation → `isLoadable == false`; key B accepted; unknown key rejected;
// high-water and cache survive a relaunch.
@testable import AntiChatPlatform
import AntiChatStorage
import CryptoKit
import Foundation
import Testing

@Suite struct CatalogVerifyTests {
    let server = FixtureServer()
    let cache = CatalogFixtures.tempDir()

    @Test func validAccepted() async throws {
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(store.snapshot.source == .baseline)
        #expect(await store.refresh() == .ok)
        #expect(store.catalog?.catalogVersion == 100)
        #expect(store.snapshot.source == .fetched)
        #expect(store.mayInstallNew)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "catalog.json").path))
    }

    @Test func badSignatureRejectedKeepsLastGood() async throws {
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        await store.refresh()
        server.serve(try CatalogFixtures.pair("catalog-bad-sig"))
        #expect(await store.refresh() == .badSignature)
        #expect(store.catalog?.catalogVersion == 100)
        #expect(store.catalog?.toneSentence.hasPrefix("Answer") == true)  // the flipped bytes were never used
        #expect(store.snapshot.status == .badSignature)
        #expect(!store.mayInstallNew)
        #expect(CatalogStatusCopy.key(store.snapshot.status) == "catalog.badSignature")
        // A good catalog lifts the latch.
        server.serve(try CatalogFixtures.pair("catalog-revoked"))
        #expect(await store.refresh() == .ok)
        #expect(store.mayInstallNew)
    }

    @Test func rollbackRejected() async throws {
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        await store.refresh()
        server.serve(try CatalogFixtures.pair("catalog-rollback"))
        #expect(await store.refresh() == .rollback)
        #expect(store.catalog?.catalogVersion == 100)
        #expect(store.snapshot.highWater == 100)
    }

    @Test func expiredAcceptedWithWarning() async throws {
        server.serve(try CatalogFixtures.pair("catalog-expired"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(await store.refresh() == .expired)
        #expect(store.catalog?.catalogVersion == 101)
        #expect(store.isLoadable("chat-9b-q4"))  // installed models keep working
        #expect(CatalogStatusCopy.key(store.snapshot.status) == "catalog.expired")
    }

    /// AT-NFR-SEC7: an expired catalog may keep installed models but never installs anything new.
    @Test func testExpiredNeverInstallsNew() async throws {
        server.serve(try CatalogFixtures.pair("catalog-expired"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        await store.refresh()
        #expect(store.mayInstallNew == false)
        // The valid catalog read on a clock past its expiry is expired too.
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        let late = CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir(), now: ISO8601DateFormatter().date(from: "2027-03-01T00:00:00Z")!)
        #expect(await late.refresh() == .expired)
        #expect(late.mayInstallNew == false)
    }

    @Test func revokedDisableIsNotLoadable() async throws {
        server.serve(try CatalogFixtures.pair("catalog-revoked"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        await store.refresh()
        #expect(store.isLoadable("chat-9b-q4") == false)
        #expect(store.isLoadable("chat-4b"))
        #expect(store.warning(for: "chat-4b")?.reason == "license")
        #expect(store.isLoadable("no-such-model") == false)
    }

    @Test func signedByKeyBAccepted() async throws {
        let data = try CatalogFixtures.data("catalog-revoked.json")
        server.serve((data, try CatalogFixtures.sig(data, key: CatalogFixtures.key("catalog-b"))))
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(await store.refresh() == .ok)
        #expect(store.catalog?.catalogVersion == 102)
    }

    @Test func unknownKeyRejected() async throws {
        let data = try CatalogFixtures.data("catalog-revoked.json")
        server.serve((data, try CatalogFixtures.sig(data, key: Curve25519.Signing.PrivateKey())))
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(await store.refresh() == .badSignature)
        #expect(store.snapshot.source == .baseline)
        #expect(!store.mayInstallNew)
    }

    @Test func highWaterAndCacheSurviveRelaunch() async throws {
        let db = try AppDatabase.inMemory()
        server.serve(try CatalogFixtures.pair("catalog-revoked"))
        do {
            let store = CatalogStore.fixture(server: server, cache: cache, database: db)
            await store.refresh()
        }
        let record = try #require(try CatalogStateRecord.load(db))
        #expect(record.highWater == 102)
        #expect(record.status == "ok")
        server.fail()
        let relaunched = CatalogStore.fixture(server: server, cache: cache, database: db)
        #expect(relaunched.snapshot.source == .cache)
        #expect(relaunched.catalog?.catalogVersion == 102)
        #expect(await relaunched.refresh() == .network)
        #expect(relaunched.catalog?.catalogVersion == 102)
        server.serve(try CatalogFixtures.pair("catalog-valid"))  // 100 < high-water 102
        #expect(await relaunched.refresh() == .rollback)
    }

    @Test func tamperedCacheFallsBackToBaseline() async throws {
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        do { await CatalogStore.fixture(server: server, cache: cache).refresh() }
        var bytes = try Data(contentsOf: cache.appending(path: "catalog.json"))
        bytes[bytes.startIndex + 10] ^= 0x01
        try bytes.write(to: cache.appending(path: "catalog.json"))
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(store.snapshot.source == .baseline)
    }
}
