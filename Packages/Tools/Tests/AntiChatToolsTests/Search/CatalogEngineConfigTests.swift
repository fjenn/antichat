// M7.T01 step 6 (AT-253, R-253 AC1): a verified catalog's `search_engines` section swaps the engine set and an
// XPath without a relaunch; a malformed section, an unknown (uncompiled) id and a too-new entry change nothing.
// The signature half (bad signature → last good) runs through CatalogStore in CatalogEngineSwapTests.
@testable import AntiChatTools
import Foundation
import Testing

struct CatalogEngineConfigTests {
    static func catalog(_ engines: [SearchEngineConfig]) throws -> Data {
        let section = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engines))
        return try JSONSerialization.data(withJSONObject: ["schema": 2, "catalog_version": 9, "search_engines": section])
    }

    @Test func overrideDisablesAnEngineAndChangesAnXPath() throws {
        let r = EngineRegistry(appVersion: "1.0.0")
        var mojeek = MojeekEngine.config; mojeek.enabled = false
        var startpage = StartpageEngine.config; startpage.xpaths?.items = "//section[@class='w-gl']/div[./a]"
        var notified = false
        let token = NotificationCenter.default.addObserver(forName: EngineRegistry.didChange, object: r, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(r.apply(catalogJSON: try Self.catalog([mojeek, startpage])))
        #expect(notified)
        #expect(r.enabled == ["duckduckgo", "brave", "startpage", "wikipedia"])
        #expect(r.configs.first { $0.id == "startpage" }?.xpaths?.items == "//section[@class='w-gl']/div[./a]")
        // The new XPath is the one the parser runs.
        let html = Data(#"<html><body><section class="w-gl"><div><a href="https://n.test/x"><h2>New</h2></a><p>p</p></div></section></body></html>"#.utf8)
        let engine = try #require(r.enabledEngines.first { $0.id == "startpage" })
        #expect(try engine.parse(status: 200, data: html).map(\.url) == ["https://n.test/x"])
        // Same document again → no change.
        #expect(!r.apply(catalogJSON: try Self.catalog([mojeek, startpage])))
    }

    @Test func unknownIdsAndParserSwapsAreIgnored() throws {
        let r = EngineRegistry(appVersion: "1.0.0")
        var google = MojeekEngine.config; google.id = "google"; google.urlTemplate = "https://www.google.com/search?q={q}"
        var ddg = OsaurusEngines.duckduckgo; ddg.parser = .xpath
        #expect(!r.apply(catalogJSON: try Self.catalog([google, ddg])))
        #expect(!r.configs.contains { $0.id == "google" })
        #expect(r.configs.first { $0.id == "duckduckgo" }?.parser == .osaurusDDG)
    }

    @Test func tooNewEntryKeepsTheDefault() throws {
        let r = EngineRegistry(appVersion: "1.0.0")
        var mojeek = MojeekEngine.config; mojeek.enabled = false; mojeek.minAppVersion = "9.0.0"
        #expect(!r.apply(catalogJSON: try Self.catalog([mojeek])))
        #expect(r.enabled.contains("mojeek"))
    }

    @Test func malformedOrMissingSectionKeepsLastGood() throws {
        let r = EngineRegistry(appVersion: "1.0.0")
        var mojeek = MojeekEngine.config; mojeek.enabled = false
        #expect(r.apply(catalogJSON: try Self.catalog([mojeek])))
        let bad = try JSONSerialization.data(withJSONObject: ["search_engines": [["id": "brave"]]])
        #expect(!r.apply(catalogJSON: bad))
        #expect(!r.apply(catalogJSON: Data("not json".utf8)))
        #expect(!r.apply(catalogJSON: try JSONSerialization.data(withJSONObject: ["schema": 2])))
        #expect(!r.apply(catalogJSON: nil))
        #expect(!r.enabled.contains("mojeek"), "last good stays")
        #expect(throws: CatalogEngineConfig.ParseError.notJSON) { try CatalogEngineConfig.section(fromCatalog: Data("x".utf8)) }
    }

    /// `catalog/search-engines.yaml` mirrors the code defaults (the catalog only needs entries that change something).
    @Test func codeDefaultsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(EngineRegistry.defaults)
        #expect(try JSONDecoder().decode([SearchEngineConfig].self, from: data) == EngineRegistry.defaults)
    }
}
