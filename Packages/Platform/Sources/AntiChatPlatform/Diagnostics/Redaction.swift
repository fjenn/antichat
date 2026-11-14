// M8.T09 step 5 (R-218 AC3; P-platform-09): redaction of everything that leaves through a log bundle, a crash
// payload or a problem report.
// Ported from osaurus@2922745 Packages/OsaurusCore/Services/SupportDiagnosticsBundle.swift (MIT):
// `redactSecretLikeSubstrings`, `sanitizedEndpoint`, `redactIdentitySegments` (+ `replacing`). AntiChat additions:
// home-directory user names → `~`, e-mail addresses, Hugging Face / GitHub / AWS / Slack style tokens, long hex
// keys, and the relay install id.
import Foundation

public enum Redaction {
    public static let redactedValue = "[REDACTED]"

    /// Every rule, in order: secrets, then endpoints' query strings, then identity segments and user paths.
    public static func redact(_ text: String) -> String {
        var out = redactSecretLikeSubstrings(text)
        out = stripQueryStrings(out)
        out = redactIdentitySegments(in: out)
        out = redactUserPaths(out)
        return out
    }

    // MARK: Ported

    public static func redactSecretLikeSubstrings(_ value: String) -> String {
        var output = value
        output = replacing(pattern: #"(?i)(bearer\s+)[^\s,;]+"#, in: output, template: "$1\(redactedValue)")
        output = replacing(pattern: #"(?i)(authorization\s*[:=]\s*)(?:basic|bearer|token)?\s*[^\s,;]+"#, in: output,
                           template: "$1\(redactedValue)")
        output = replacing(
            pattern: #"(?i)((?:^|[^\w])"?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|code|install[_-]?id)"?\s*[=:]\s*)"?[^\s"&;,}]+"?"#,
            in: output, template: "$1\(redactedValue)")
        output = replacing(pattern: #"(?i)([a-z][a-z0-9+.-]*://)[^/@:\s]+(?::[^/@\s]*)?@"#, in: output, template: "$1\(redactedValue)@")
        output = replacing(pattern: #"\bsk-[A-Za-z0-9._-]{8,}\b"#, in: output, template: redactedValue)
        // AntiChat additions: provider token shapes and long hex keys.
        output = replacing(pattern: #"\b(?:hf_|ghp_|gho_|github_pat_|xox[abpr]-|AKIA)[A-Za-z0-9_-]{8,}\b"#, in: output, template: redactedValue)
        output = replacing(pattern: #"\b[0-9a-fA-F]{40,}\b"#, in: output, template: redactedValue)
        output = replacing(pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, in: output, template: "[email]")
        return output
    }

    public static func sanitizedEndpoint(_ value: String) -> String {
        let withoutQuery = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let withoutFragment = withoutQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutQuery
        return redactIdentitySegments(in: redactSecretLikeSubstrings(withoutFragment))
    }

    public static func redactIdentitySegments(in value: String) -> String {
        var output = value
        output = replacing(pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, in: output, template: "[uuid]")
        output = replacing(pattern: #"\b0x[0-9A-Fa-f]{40}\b"#, in: output, template: "0x[REDACTED]")
        output = replacing(pattern: #"/[A-Za-z0-9._~%-]{32,}(?=/|$)"#, in: output, template: "/[id]")
        return output
    }

    /// Compiled once per pattern (review fix: a log bundle redacts thousands of lines).
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression] = [:]
    private static let compiledLock = NSLock()

    static func expression(_ pattern: String) -> NSRegularExpression? {
        compiledLock.lock(); defer { compiledLock.unlock() }
        if let e = compiled[pattern] { return e }
        guard let e = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiled[pattern] = e
        return e
    }

    static func replacing(pattern: String, in value: String, template: String) -> String {
        guard let expression = expression(pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }

    // MARK: AntiChat

    /// `scheme://host/path?query#frag` → `scheme://host/path` anywhere in free text.
    public static func stripQueryStrings(_ value: String) -> String {
        replacing(pattern: #"(\b[a-z][a-z0-9+.-]*://[^\s?#"'<>]+)[?#][^\s"'<>]*"#, in: value, template: "$1")
    }

    /// `/Users/<name>/…` and `/home/<name>/…` → `~/…`; the current user's name anywhere else → `[user]`.
    public static func redactUserPaths(_ value: String, userName: String = NSUserName()) -> String {
        var out = replacing(pattern: #"/(?:Users|home)/[^/\s"']+"#, in: value, template: "~")
        if userName.count >= 3 {
            out = replacing(pattern: "\\b" + NSRegularExpression.escapedPattern(for: userName) + "\\b", in: out, template: "[user]")
        }
        return out
    }
}
