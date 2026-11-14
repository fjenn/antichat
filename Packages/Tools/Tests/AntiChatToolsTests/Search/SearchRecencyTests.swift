// M7 verifier: latest/current-version questions get the swapped-phrasing query and the results that state the latest
// version inside the fetched window (generic by query intent; nothing filtered).
@testable import AntiChatTools
import OsaurusVendored
import Testing

@Suite struct SearchRecencyTests {
    static func hit(_ url: String, _ snippet: String) -> SearchHit { SearchHit(title: url, url: url, snippet: snippet, engine: "t") }

    @Test func intentIsTheLatestOrCurrentVersion() {
        #expect(SearchRecency.asksLatest(["latest macOS version"]) && SearchRecency.asksLatest(["What's the current release of Postgres?"]))
        #expect(SearchRecency.asksLatest(["node version latest"]) && SearchRecency.asksLatest(["what version of python is newest"]))
        #expect(!SearchRecency.asksLatest(["population of Lyon"]) && !SearchRecency.asksLatest(["latest news on the election"]))
    }

    @Test func oneSwappedQueryIsAdded() {
        #expect(SearchRecency.queries(["latest macOS version"]) == ["latest macOS version", "current macOS version"])
        #expect(SearchRecency.queries(["Current Rust release", "rust changelog"]) == ["Current Rust release", "rust changelog", "latest Rust release"])
        #expect(SearchRecency.queries(["latest macOS version", "current macOS version"]) == ["latest macOS version", "current macOS version"])
        #expect(SearchRecency.queries(["population of Lyon"]) == ["population of Lyon"])
    }

    @Test func theSwappedQueryDropsAYear() {
        #expect(SearchRecency.queries(["latest macOS version 2026"]) == ["latest macOS version 2026", "current macOS version"])
        #expect(SearchRecency.queries(["current Postgres release in 2026"]) == ["current Postgres release in 2026", "latest Postgres release"])
        // a version number is not a year
        #expect(SearchRecency.queries(["latest iOS 26 release"]) == ["latest iOS 26 release", "current iOS 26 release"])
    }

    @Test func resultsStatingTheLatestVersionMoveIntoTheWindowAndNothingIsDropped() {
        let hits = [Self.hit("a", "Every version in order"), Self.hit("b", "Release notes"), Self.hit("c", "Update your Mac"),
                    Self.hit("d", "Which macOS is the latest? Check compatibility"), Self.hit("e", "macOS 27 is the latest version of macOS"),
                    Self.hit("f", "Use these methods to download")]
        #expect(SearchRecency.statesLatest(hits[3]) && SearchRecency.statesLatest(hits[4]) && !SearchRecency.statesLatest(hits[0]))
        let out = SearchRecency.promote(hits, window: 3)
        #expect(out.prefix(3).map(\.url) == ["a", "d", "e"])
        #expect(Set(out.map(\.url)) == Set(hits.map(\.url)) && out.count == hits.count)
        #expect(SearchRecency.promote(hits, window: 6) == hits)
    }
}
