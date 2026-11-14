// R-091 AC3 / R-109 (M8.T08 setting × M7 search): the coarse region hint. Off (no provider / provider nil) → no
// region parameter in any engine request; on → DuckDuckGo carries `kl=<cc>-<lang>`, sent through the transport like
// every other byte (the gate's ledger row is the request itself); an incognito broker never sends it; only a
// two-letter country code is ever accepted (no coordinates, no city).
import AntiChatNetwork
@testable import AntiChatTools
import Foundation
import Testing

@Suite(.serialized) struct SearchRegionTests {
    final class Recorder: SearchTransport, @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
            lock.withLock { urls.append(request.url!) }
            return (500, Data())
        }
        var all: [URL] { lock.withLock { urls } }
    }

    static func ddgURLs(_ broker: SearchBroker, _ rec: Recorder) async -> [URL] {
        _ = await broker.search(queries: ["weather tomorrow"])
        return rec.all.filter { $0.host()?.contains("duckduckgo") == true }
    }

    static func kl(_ u: URL) -> String? { URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kl" }?.value }

    @Test func offByDefaultSendsNoRegion() async {
        SearchRegion.use(nil)
        defer { SearchRegion.use(nil) }
        let rec = Recorder()
        let urls = await Self.ddgURLs(SearchBroker(transport: rec, safeSearch: { false }), rec)
        #expect(!urls.isEmpty)
        #expect(urls.allSatisfy { Self.kl($0) == "wt-wt" }, "worldwide default, no region")
        SearchRegion.use { nil }  // setting on but no permission / no region
        #expect(SearchRegion.current(incognito: false) == nil)
    }

    @Test func onSendsCountryOnly() async {
        SearchRegion.use { "DE" }
        defer { SearchRegion.use(nil) }
        let rec = Recorder()
        let urls = await Self.ddgURLs(SearchBroker(transport: rec, safeSearch: { false }), rec)
        #expect(!urls.isEmpty && urls.allSatisfy { Self.kl($0) == "de-en" })
        // other engines get no region parameter (and no coordinates anywhere)
        #expect(rec.all.allSatisfy { !$0.absoluteString.contains("lat") && !$0.absoluteString.contains("lon=") })
        SearchRegion.use { "GB" }
        #expect(SearchRegion.parameter(engine: "duckduckgo", country: SearchRegion.current(incognito: false)!)?.value == "uk-en")
    }

    @Test func incognitoNeverSendsIt() async {
        SearchRegion.use { "fr" }
        defer { SearchRegion.use(nil) }
        #expect(SearchRegion.current(incognito: true) == nil)
        let rec = Recorder()
        let urls = await Self.ddgURLs(SearchBroker(transport: rec, safeSearch: { false }, incognito: true), rec)
        #expect(!urls.isEmpty && urls.allSatisfy { Self.kl($0) == "wt-wt" })
    }

    @Test func onlyTwoLetterCountryCodes() {
        defer { SearchRegion.use(nil) }
        for bad in ["52.52,13.40", "Berlin", "DEU", "", "d1"] {
            SearchRegion.use { bad }
            #expect(SearchRegion.current(incognito: false) == nil, "\(bad)")
        }
    }
}
