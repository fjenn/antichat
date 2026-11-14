// M2.T05 AT-220 part 2 (R-220 AC4): fully offline with the last cached catalog. With no network and an empty cache
// the bundled baseline is used; with a cache the cache is used; every slot of the catalog in use resolves to
// entries it contains (the full selector assignment is asserted in M2.T06).
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct CatalogOfflineTests {
    @Test func emptyCacheUsesBaseline() async throws {
        let server = FixtureServer()
        server.fail()
        let store = CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir())
        #expect(await store.refresh() == .network)
        #expect(store.snapshot.source == .baseline)
        #expect(store.catalog != nil)
        #expect(store.mayInstallNew)  // the baseline is verified and unexpired
        try assertEverySlotResolves(try #require(store.catalog))
    }

    @Test func cacheUsedOffline() async throws {
        let server = FixtureServer()
        let cache = CatalogFixtures.tempDir()
        server.serve(try CatalogFixtures.pair("catalog-revoked"))
        await CatalogStore.fixture(server: server, cache: cache).refresh()
        server.fail()
        let store = CatalogStore.fixture(server: server, cache: cache)
        #expect(await store.refresh() == .network)
        #expect(store.snapshot.source == .cache)
        #expect(store.catalog?.catalogVersion == 102)
        try assertEverySlotResolves(try #require(store.catalog))
    }

    @Test func noCatalogAtAllInstallsNothing() {
        let server = FixtureServer()
        server.fail()
        let store = CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir(), baseline: nil)
        #expect(store.catalog == nil)
        #expect(!store.mayInstallNew)
    }

    /// M9.T05: the app's turn model is `turn-coreml` (`VoiceModelRole.turn.catalogKey`; SetupLaunch maps install ids to
    /// roles by that key). Every Voice pack of the shipped catalog installs it as Core ML, so no user ends up with only
    /// the ONNX `turn` (which no role maps to) and no turn detection.
    @Test func everyVoicePackInstallsTheCoreMLTurnModel() throws {
        let server = FixtureServer()
        server.fail()
        let c = try #require(CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir()).catalog)
        #expect(c.models["turn-coreml"]?.engine == "coreml")
        for (key, classes) in c.assignments {
            for (sc, cell) in classes {
                guard let voice = cell.voice else { continue }
                for ids in [voice.normal, voice.evil] where !ids.isEmpty {
                    #expect(ids.contains("turn-coreml"), "\(key)/\(sc.rawValue): \(ids)")
                }
            }
        }
    }

    func assertEverySlotResolves(_ c: ModelCatalog) throws {
        #expect(c.assignments.count == 9)
        for (key, classes) in c.assignments {
            #expect(Set(classes.keys) == Set(SpeedClass.allCases), "\(key)")
            for (sc, cell) in classes {
                var ids = [cell.chat.fastFirst] + [cell.chat.normal?.model, cell.chat.evil?.model, cell.embed, cell.rerank].compactMap { $0 }
                for p in [cell.voice, cell.photo, cell.video].compactMap({ $0 }) { ids += p.normal + p.evil }
                for id in ids { #expect(c.models[id] != nil, "\(key)/\(sc.rawValue): \(id)") }
                #expect(cell.photo != nil || cell.photoReason != nil)
                #expect(cell.video != nil || cell.videoReason != nil)
            }
        }
    }
}
