// M7.T06 step 1 (R-258; A-M7-03): the MCP protocol revisions AntiChat accepts, newest first. The swift-sdk client at
// the A-M7-02 pin requests `Version.latest` (2025-11-25) and the server answers with the revision it speaks; a
// connection is kept only when that answer is one of `acceptedVersions`.
// The 2026-07-28 profile sits behind `Defaults[.mcpModernProfile]` (UserDefaults key `mcp.modernProfile`, off).
// It needs swift-sdk PR #314 ("dual-era MCP 2026-07-28 modern protocol profile"), still open on 2026-11-05, and no
// TypeScript SDK release speaks 2026-07-28 yet (@modelcontextprotocol/core 2.3.1: latest 2025-11-25), so there is no
// reference server to port the header / `server/discover` handling against: `status` records
// `pending PR #314` and the flag only adds the revision to the accepted list (A-M7-03, AT-258).
import AntiChatFoundation
import Foundation
import MCP

public enum ModernProfile {
    public static let defaultsKey = "mcp.modernProfile"
    public static let modernVersion = "2026-07-28"
    public static let baseVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// What AT-258 records for the modern leg.
    public static var status: String { sdkSupportsModern ? "available" : "pending PR #314" }
    /// Whether the linked swift-sdk can speak 2026-07-28.
    public static var sdkSupportsModern: Bool { Version.supported.contains(modernVersion) }

    public static var enabled: Bool { AppDefaults.standard.bool(forKey: defaultsKey) }

    /// Newest first: 2026-07-28 only with the flag on and an SDK that speaks it.
    public static func acceptedVersions(modern: Bool = enabled) -> [String] {
        (modern && sdkSupportsModern ? [modernVersion] : []) + baseVersions
    }
}
