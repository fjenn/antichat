// M7.T16 review #11: `web_search`'s freshness / category reach the engines' own date parameters.
//   make test-unit FILTER=SearchFreshnessTests
@testable import AntiChatTools
import Foundation
import Testing

struct SearchFreshnessTests {
    @Test func effectiveFilter() {
        #expect(SearchFreshness.effective(freshness: "day", category: nil) == "day")
        #expect(SearchFreshness.effective(freshness: "any", category: "news") == nil)
        #expect(SearchFreshness.effective(freshness: nil, category: "news") == "week")
        #expect(SearchFreshness.effective(freshness: nil, category: "general") == nil)
        #expect(SearchFreshness.effective(freshness: "year", category: nil) == nil)
    }

    @Test func enginesCarryTheirDateParameter() throws {
        func query(_ e: SearchEngineConfig, _ f: String?) throws -> [URLQueryItem] {
            let r = try #require(WebSearchEngine(e).request(query: "macos", safeSearch: false, freshness: f))
            return URLComponents(url: try #require(r.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        }
        #expect(try query(OsaurusEngines.duckduckgo, "week").contains(URLQueryItem(name: "df", value: "w")))
        #expect(try query(OsaurusEngines.brave, "day").contains(URLQueryItem(name: "tf", value: "pd")))
        #expect(try !query(OsaurusEngines.duckduckgo, nil).contains { $0.name == "df" })
        #expect(SearchFreshness.parameter(engine: "startpage", freshness: "month") == URLQueryItem(name: "with_date", value: "m"))
        #expect(SearchFreshness.parameter(engine: "wikipedia", freshness: "day") == nil)
    }
}
