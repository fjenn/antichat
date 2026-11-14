//
//  SearchProviderConfigurationTests.swift
//  OsaurusCoreTests
//
//  Contract tests for the native search-provider configuration model:
//  default config (free scrapers enabled), per-category routing resolution,
//  provider removal scrubbing routing entries, Codable round-trips (including
//  forward-compatible decoding of sparse JSON), the store's load/save cycle,
//  catalog invariants, keychain-disabled no-op behavior, and the plugin-key
//  migration map's integrity against the bundled catalog.
//

import Foundation
import Testing

// ANTICHAT-PATCH: UP-OS-034 ported test imports the OsaurusVendored target
@testable import OsaurusVendored
// ANTICHAT-PATCH-END

// ANTICHAT-PATCH: UP-OS-020 tests install VendoredTestHooks (temp search-provider dir, plain sessions)
@Suite(.serialized)
@MainActor
struct SearchProviderConfigurationTests {
    init() { _ = VendoredTestHooks.install }
// ANTICHAT-PATCH-END

    // MARK: - Defaults

    @Test func defaultConfigurationSeedsFreeScrapersEnabled() {
        let config = SearchProviderConfiguration.makeDefault()
        #expect(config.providers.map(\.definitionId) == SearchProviderCatalog.freeProviderIds)
        #expect(config.providers.allSatisfy { $0.enabled })
        #expect(config.routing.isEmpty)
        #expect(!config.pluginKeysMigrated)
    }

    // MARK: - Routing resolution

    @Test func rankingWithoutOverrideUsesProviderOrder() {
        var config = SearchProviderConfiguration.makeDefault()
        config.providers.insert(SearchProvider(definitionId: "tavily"), at: 0)
        #expect(config.ranking(for: "web") == ["tavily", "brave_html", "bing_html", "ddg"])
        #expect(config.ranking(for: "news") == config.ranking(for: "web"))
    }

    @Test func defaultFreeOrderDemotesDDGToLast() {
        // DDG serves decoy results to flagged clients; it must rank after the
        // trusted scrapers and carry the lastResort flag.
        #expect(SearchProviderCatalog.freeProviderIds == ["brave_html", "bing_html", "ddg"])
        #expect(SearchProviderCatalog.definition(id: "ddg")?.lastResort == true)
        #expect(SearchProviderCatalog.definition(id: "brave_html")?.lastResort == false)
        #expect(SearchProviderCatalog.definition(id: "bing_html")?.lastResort == false)
    }

    @Test func rankingOverrideReordersDropsUnknownAndAppendsMissing() {
        var config = SearchProviderConfiguration(
            providers: [
                SearchProvider(definitionId: "tavily"),
                SearchProvider(definitionId: "brave_api"),
                SearchProvider(definitionId: "ddg"),
            ],
            routing: [
                // "ghost" was removed from providers; ddg is missing from the
                // override and must be appended so it stays routable.
                "news": ["brave_api", "ghost", "tavily"]
            ]
        )
        #expect(config.ranking(for: "news") == ["brave_api", "tavily", "ddg"])
        // Other categories are untouched by the override.
        #expect(config.ranking(for: "web") == ["tavily", "brave_api", "ddg"])
        // Duplicate ids in a hand-edited override must not duplicate output.
        config.routing["news"] = ["brave_api", "brave_api"]
        #expect(config.ranking(for: "news") == ["brave_api", "tavily", "ddg"])
    }

    @Test func removeScrubsProviderAndRoutingEntries() {
        var config = SearchProviderConfiguration(
            providers: [
                SearchProvider(definitionId: "tavily"),
                SearchProvider(definitionId: "ddg"),
            ],
            routing: ["web": ["tavily", "ddg"], "news": ["tavily"]]
        )
        config.remove(definitionId: "tavily")
        #expect(config.providers.map(\.definitionId) == ["ddg"])
        #expect(config.routing["web"] == ["ddg"])
        #expect(config.routing["news"] == [])
    }

    // MARK: - Codable

    @Test func configurationRoundTripsThroughJSON() throws {
        let original = SearchProviderConfiguration(
            providers: [
                SearchProvider(definitionId: "tavily", enabled: true),
                SearchProvider(definitionId: "ddg", enabled: false),
            ],
            routing: ["news": ["tavily"]],
            pluginKeysMigrated: true,
            hostedSearchEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SearchProviderConfiguration.self, from: data)
        #expect(decoded.providers == original.providers)
        #expect(decoded.routing == original.routing)
        #expect(decoded.pluginKeysMigrated == original.pluginKeysMigrated)
        #expect(decoded.hostedSearchEnabled == false)
    }

    @Test func configurationDecodesSparseJSONWithDefaults() throws {
        let decoded = try JSONDecoder().decode(
            SearchProviderConfiguration.self, from: Data("{}".utf8))
        #expect(decoded.providers.isEmpty)
        #expect(decoded.routing.isEmpty)
        #expect(!decoded.pluginKeysMigrated)
        // Pre-premium configs decode as "never resolved" so the manager's
        // one-time default resolution runs exactly once for them.
        #expect(decoded.hostedSearchEnabled == nil)
    }

    @Test func definitionDecodesMinimalJSONWithDefaults() throws {
        let json = #"{"id": "exa", "name": "Exa"}"#
        let def = try JSONDecoder().decode(SearchProviderDefinition.self, from: Data(json.utf8))
        #expect(def.runtime == .declarative)
        #expect(def.isKeyless)
        #expect(!def.recommended)
        #expect(def.supportedCategories.isEmpty)
    }

    // MARK: - Store round-trip

    @Test func storeRoundTripsConfiguration() throws {
        // ANTICHAT-PATCH: UP-OS-020 test store round-trip in a temp directory via OsaurusPathHooks (never the user's real config)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-store-\(UUID().uuidString)")
        let previousHook = OsaurusPathHooks.searchProvidersDirectory
        OsaurusPathHooks.searchProvidersDirectory = { dir }
        defer {
            OsaurusPathHooks.searchProvidersDirectory = previousHook
            try? FileManager.default.removeItem(at: dir)
        }
        let url = OsaurusPathHooks.searchProviderConfigFile()
        // ANTICHAT-PATCH-END
        let previous = try? Data(contentsOf: url)
        defer {
            if let previous {
                try? previous.write(to: url, options: [.atomic])
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let config = SearchProviderConfiguration(
            providers: [
                SearchProvider(definitionId: "serper", enabled: true),
                SearchProvider(definitionId: "ddg", enabled: true),
            ],
            routing: ["images": ["ddg"]],
            pluginKeysMigrated: true
        )
        SearchProviderConfigurationStore.save(config)
        let loaded = SearchProviderConfigurationStore.load()
        #expect(loaded.providers == config.providers)
        #expect(loaded.routing == config.routing)
        #expect(loaded.pluginKeysMigrated)
    }

    @Test func customDefinitionStoreRoundTripsAndIgnoresBundledIdShadowing() throws {
        let customId = "test_custom_\(UUID().uuidString.prefix(6).lowercased())"
        defer { SearchProviderDefinitionStore.delete(definitionId: customId) }

        let def = SearchProviderDefinition(
            id: customId,
            name: "Test Custom",
            endpoints: [
                "web": SearchEndpoint(
                    url: "https://example.com/search",
                    query: [SearchRequestParam(name: "q", value: "{{query}}")],
                    response: SearchResponseMapping(
                        resultsPath: "results",
                        item: SearchHitFieldPaths(title: "title", url: "url", snippet: "snippet")
                    )
                )
            ]
        )
        try SearchProviderDefinitionStore.save(def)
        #expect(SearchProviderDefinitionStore.loadCustom().contains { $0.id == customId })

        // A custom file that shadows a bundled id must be ignored on load —
        // the catalog always wins.
        var shadow = def
        shadow.id = "tavily"
        try SearchProviderDefinitionStore.save(shadow)
        defer { SearchProviderDefinitionStore.delete(definitionId: "tavily") }
        #expect(!SearchProviderDefinitionStore.loadCustom().contains { $0.id == "tavily" })
    }

    // MARK: - Catalog invariants

    @Test func catalogProvidesTheDocumentedProviders() {
        let ids = Set(SearchProviderCatalog.bundled.map(\.id))
        // ANTICHAT-PATCH: UP-OS-040 no google_cse provider is compiled (UP-OS-039)
        for expected in ["tavily", "exa", "brave_api", "serper", "parallel", "kagi", "you"] {
        // ANTICHAT-PATCH-END
            #expect(ids.contains(expected), "missing bundled API provider \(expected)")
        }
        for free in SearchProviderCatalog.freeProviderIds {
            let def = SearchProviderCatalog.definition(id: free)
            #expect(def != nil, "missing free provider \(free)")
            #expect(def?.isKeyless == true, "\(free) must be keyless")
            #expect(def?.runtime == .native, "\(free) must be a native scraper")
        }
        // API providers all declare secrets and at least a web endpoint.
        for def in SearchProviderCatalog.apiProviders {
            #expect(!def.isKeyless, "\(def.id) must require a key")
            #expect(def.supports(category: SearchCategory.web), "\(def.id) must support web")
        }
        #expect(ids.count == SearchProviderCatalog.bundled.count, "duplicate catalog ids")
    }

    @Test func exaAndParallelDefinitionsAreWellFormed() {
        let exa = SearchProviderCatalog.definition(id: "exa")
        #expect(exa?.recommended == true)
        #expect(exa?.supports(category: SearchCategory.news) == true)
        #expect(exa?.secrets?.map(\.id) == ["api_key"])
        #expect(exa?.endpoints?[SearchCategory.web]?.method == "POST")

        let parallel = SearchProviderCatalog.definition(id: "parallel")
        #expect(parallel?.supportedCategories == [SearchCategory.web])
        #expect(parallel?.secrets?.map(\.id) == ["api_key"])
        // Parallel has no free tier — the pricing note must say so plainly.
        #expect(parallel?.pricingNote?.lowercased().contains("paid") == true)

        // Brave's free tier was retired; stale "free" copy would mislead users.
        let braveAPI = SearchProviderCatalog.definition(id: "brave_api")
        #expect(braveAPI?.pricingNote?.lowercased().contains("paid") == true)
    }

    @Test func supportedCategoriesSortWebNewsImagesFirst() {
        let def = SearchProviderDefinition(
            id: "probe",
            name: "Probe",
            categories: ["academic", "images", "web", "news"]
        )
        #expect(def.supportedCategories == ["web", "news", "images", "academic"])
    }

    // MARK: - Keychain-disabled behavior

    @Test func keychainDisabledModeIsANoOp() {
        // Tests run with OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1; assert the
        // wrapper honors it. When run without the flag (keychain-gated lane)
        // this test is a no-op.
        guard KeychainQueryHelpers.disablesKeychainForProcess else { return }
        #expect(!SearchProviderKeychain.saveSecret("v", field: "api_key", for: "probe"))
        #expect(SearchProviderKeychain.getSecret(field: "api_key", for: "probe") == nil)
        #expect(SearchProviderKeychain.deleteSecret(field: "api_key", for: "probe"))
        // A definition with declared secrets can never be "configured".
        #expect(SearchProviderCatalog.tavily.hasAllSecrets() == false)
    }

    // MARK: - Plugin key migration map

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests of the Osaurus SearchProviderManager/PluginManager (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests of the Osaurus SearchProviderManager/PluginManager (not vendored)
    // ANTICHAT-PATCH-END
}
