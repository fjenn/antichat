// M7.T01 step 7 (R-241 AC3, settings-map §7 "Safe search results: Off"): a user option passed to each engine as its
// own query parameter. Off by default, the same in Normal and Evil Mode. This is the only search code that mentions
// safety; it maps a setting to a URL parameter and inspects no content (D-005/D-006; r241-allowlist, M7.T15).
import AntiChatFoundation
import Foundation

public enum SafeSearch {
    /// Settings key (Tools & Connections → Web search → "Safe search results"); absent = off.
    /// M7.T15: the Settings key `Defaults[.safeSearch]` (Keys.swift) in the app's settings store (`ToolDefaults.store`:
    /// the app domain, or DEBUG `-DefaultsSuite`), so a probe never reads or writes the developer's own setting.
    public static let defaultsKey = "safeSearch"
    public static let defaultOn = false

    /// The stored user choice (`defaults` = the app's suite).
    public static func isOn(_ defaults: UserDefaults = ToolDefaults.store) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? defaultOn
    }

    /// The engine's catalog parameter for the setting: `safe_param.off` when off, `.on` when on. Nil when the engine
    /// has none (Wikipedia). The chat mode is not an input: Normal and Evil send the same value.
    public static func parameter(for engine: SearchEngineConfig, on: Bool) -> URLQueryItem? {
        let raw = on ? engine.safeParam.on : engine.safeParam.off
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        return URLQueryItem(name: parts[0], value: parts.count > 1 ? parts[1] : "")
    }
}
