// M7.T01 AT-253 (R-253 AC1): the composition-root wiring (CatalogLaunch.wireSearchEngines) over a real CatalogStore
// and the pinned (Debug: test) keys. A signed catalog with Mojeek disabled and a new Startpage XPath changes the live
// engine set without a relaunch; `catalog-bad-sig.json` changes nothing and raises `catalog.badSignature`.
// Fixtures: fixtures/catalog/catalog-search-swap.json(+.sig, + .startpage.html) from make-catalog-search-swap.py.
import AntiChatPlatform
import AntiChatTools
@testable import AntiChatUI
import Foundation
import Testing

@Suite(.serialized, .isolatedSettings) struct CatalogEngineSwapTests {
    static let fixtures: URL = {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appending(path: "fixtures")
    }()

    /// Serves `<name>` and `<name>.sig` from fixtures/catalog for whatever file `current` names.
    final class Server: @unchecked Sendable {
        let lock = NSLock()
        var current = "catalog-search-swap.json"
        func fetch(_ url: URL) throws -> Data {
            let name = lock.withLock { current }
            let file = url.lastPathComponent.hasSuffix(".sig") ? name + ".sig" : name
            return try Data(contentsOf: CatalogEngineSwapTests.fixtures.appending(path: "catalog/\(file)"))
        }
    }

    @Test func validCatalogSwapsEnginesBadSignatureChangesNothing() async throws {
        let server = Server()
        let cache = FileManager.default.temporaryDirectory.appending(path: "swap-\(UUID().uuidString)")
        let store = CatalogStore(url: URL(string: "http://127.0.0.1:4321/catalog/v2/catalog.json")!, cacheDirectory: cache,
                                 database: nil, baseline: nil, fetch: { try server.fetch($0) })
        let registry = EngineRegistry(appVersion: "1.0.0")
        let token = CatalogLaunch.wireSearchEngines(store: store, registry: registry)
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(registry.enabled == ["duckduckgo", "brave", "mojeek", "startpage", "wikipedia"])

        // Valid, signed update → applied in place.
        #expect(await store.refresh() == .ok)
        #expect(registry.enabled == ["duckduckgo", "brave", "startpage", "wikipedia"])
        let startpage = try #require(registry.enabledEngines.first { $0.id == "startpage" })
        let page = try Data(contentsOf: Self.fixtures.appending(path: "catalog/catalog-search-swap.startpage.html"))
        #expect(try startpage.parse(status: 200, data: page).map(\.url) == ["https://swap.test/new"])

        // Bad signature → last good stays, the status says so.
        server.lock.withLock { server.current = "catalog-bad-sig.json" }
        #expect(await store.refresh() == .badSignature)
        #expect(CatalogStatusCopy.key(store.snapshot.status) == "catalog.badSignature")
        #expect(registry.enabled == ["duckduckgo", "brave", "startpage", "wikipedia"])
        #expect(registry.configs.first { $0.id == "startpage" }?.xpaths?.items == "//section[contains(@class, 'w-gl')]/div[./a]")

        let log = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "after_valid": ["duckduckgo", "brave", "startpage", "wikipedia"].joined(separator: ","),
            "after_bad_sig": registry.enabled.joined(separator: ","), "status": store.snapshot.status.rawValue,
        ]
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/at/AT-253")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appending(path: "\(String(ISO8601DateFormatter().string(from: Date()).prefix(10))).json"))
    }
}
