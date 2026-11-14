// M8.T08 × M7 (R-091 AC3, R-109; settings-map §7 `searchUsesLocation`): "Use my approximate location for search".
// Off by default. Only when the setting is on (and macOS Location is granted — the composition root decides) does a
// search request carry a coarse region hint: an ISO 3166-1 alpha-2 country code, never coordinates, never a city.
// It rides on the engine's own region parameter (DuckDuckGo `kl=<cc>-<lang>`; the other engines have no documented
// region parameter in their keyless pages and get nothing), so it goes through NetworkGate with the request and the
// Network activity ledger shows the request as usual. An incognito chat never sends it.
import Foundation
import Synchronization

public enum SearchRegion {
    final class Box: Sendable {
        let provider = Mutex<(@Sendable () -> String?)?>(nil)
    }
    static let box = Box()

    /// The composition root's source of the hint (nil = none: setting off, permission missing or unknown region).
    public static func use(_ provider: (@Sendable () -> String?)?) { box.provider.withLock { $0 = provider } }

    /// The hint for a search right now: a valid two-letter country code, or nil (off, incognito, anything else).
    public static func current(incognito: Bool) -> String? {
        guard !incognito, let p = box.provider.withLock({ $0 }), let raw = p() else { return nil }
        let cc = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard cc.count == 2, cc.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return cc
    }

    /// The engine's region parameter for country `cc` (nil = the engine takes none).
    public static func parameter(engine: String, country cc: String, lang: String = "en") -> URLQueryItem? {
        switch engine {
        case "duckduckgo": URLQueryItem(name: "kl", value: "\(cc == "gb" ? "uk" : cc)-\(lang)")
        default: nil
        }
    }
}
