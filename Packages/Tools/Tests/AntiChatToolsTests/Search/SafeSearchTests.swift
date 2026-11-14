// M7.T01 step 7 (AT-241 c3 part, R-241 AC3): every engine request carries the engine's *off* parameter by default,
// identically in Normal and Evil Mode (the mode is not an input to the search code at all).
@testable import AntiChatTools
import AntiChatFoundation
import Foundation
import Testing

struct SafeSearchTests {
    static let expectedOff: [String: String?] = [
        "duckduckgo": "kp=-2", "brave": "safesearch=off", "mojeek": "safe=0", "startpage": "qadf=none",
        "wikipedia": nil, "bing": "adlt=off",
    ]

    @Test func defaultIsOff() {
        let d = UserDefaults.inMemory()
        #expect(SafeSearch.isOn(d) == false)
        d.set(true, forKey: SafeSearch.defaultsKey)
        #expect(SafeSearch.isOn(d) == true)
    }

    @Test(arguments: ["normal", "evil"])
    func everyEngineSendsTheOffParameter(mode: String) throws {
        for config in EngineRegistry.defaults {
            let req = try #require(WebSearchEngine(config).request(query: "test words", safeSearch: false), "\(config.id) \(mode)")
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let rendered = items.map { "\($0.name)=\($0.value ?? "")" }
            if let off = Self.expectedOff[config.id] ?? nil {
                #expect(rendered.contains(off), "\(config.id) \(mode): \(rendered)")
                #expect(SafeSearch.parameter(for: config, on: false).map { "\($0.name)=\($0.value ?? "")" } == off)
            } else {
                #expect(SafeSearch.parameter(for: config, on: false) == nil, "\(config.id)")
            }
        }
    }

    @Test func onUsesTheEngineSafeValueAndReplacesNotDuplicates() throws {
        let req = try #require(WebSearchEngine(OsaurusEngines.duckduckgo).request(query: "q", safeSearch: true))
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "kp" }.map(\.value) == ["1"])
    }

    @Test func onlyTheQueryWordsAreSent() throws {
        for config in EngineRegistry.defaults {
            let req = try #require(WebSearchEngine(config).request(query: "how to boil an egg", safeSearch: false))
            #expect(req.httpBody == nil && req.httpMethod == "GET", "\(config.id)")
            #expect(req.value(forHTTPHeaderField: "Cookie") == nil && req.value(forHTTPHeaderField: "Authorization") == nil)
            let values = (URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap(\.value)
            #expect(values.contains("how to boil an egg"), "\(config.id): \(values)")
        }
    }
}
