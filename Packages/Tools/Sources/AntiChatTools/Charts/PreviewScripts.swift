// M6.T13 (R-016 AC2, A-M6-08): the vendored dist scripts the side panel's sandboxed preview inlines into its pages —
// React 18.3.1 + ReactDOM UMD production builds, @babel/standalone (JSX/TSX → JS in the page) and the T09 Vega bundles.
// They are read from this module's `Resources/js` (`make vendor-js`) and inlined as text; no preview ever loads a URL.
import Foundation

public enum PreviewScripts {
    public enum Script: String, CaseIterable, Sendable {
        case react = "react.production.min"
        case reactDOM = "react-dom.production.min"
        case babel = "babel.min"
        case vega = "vega.min"
        case vegaLite = "vega-lite.min"
        case vegaEmbed = "vega-embed.min"
    }

    nonisolated(unsafe) private static var cache: [Script: String] = [:]
    private static let lock = NSLock()

    /// The script's text, or nil when the resource is missing (a broken build: previews then show their error state).
    public static func source(_ b: Script) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[b] { return s }
        guard let dir = Bundle.module.url(forResource: "js", withExtension: nil),
              let s = try? String(contentsOf: dir.appendingPathComponent("\(b.rawValue).js"), encoding: .utf8)
        else { return nil }
        cache[b] = s
        return s
    }
}
