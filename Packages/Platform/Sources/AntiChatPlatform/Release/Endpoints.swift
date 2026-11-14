// M10.T05 (hosting switch): one lookup for Config/Endpoints.plist. Release builds read the production keys
// (written from Config/Hosting.json by tools/release/set-hosting.py); Debug builds prefer the `<Key>Dev` twin (the
// local site, `make site-dev`) so development never talks to the public hosts.
import AntiChatStorage
import Foundation

public enum Endpoints {
    public static func string(_ key: String, bundle: Bundle = .main, debug: Bool = AppDatabaseFlags.isDebugBuild) -> String? {
        guard let p = bundle.url(forResource: "Endpoints", withExtension: "plist"),
              let d = NSDictionary(contentsOf: p) as? [String: Any] else { return nil }
        return resolve(key, in: d, debug: debug)
    }

    /// Pure (unit-tested): Debug → `<key>Dev` when present, else `<key>`.
    public static func resolve(_ key: String, in d: [String: Any], debug: Bool) -> String? {
        if debug, let v = d[key + "Dev"] as? String, !v.isEmpty { return v }
        return d[key] as? String
    }

    public static func url(_ key: String, bundle: Bundle = .main, debug: Bool = AppDatabaseFlags.isDebugBuild) -> URL? {
        string(key, bundle: bundle, debug: debug).flatMap(URL.init(string:))
    }
}
