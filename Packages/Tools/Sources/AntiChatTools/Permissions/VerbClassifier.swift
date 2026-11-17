// M7.T06 step 6 (R-081 AC2) + M7.T11 step 5 (R-256): is a tool a write by its name? Splits `send_message`,
// `createIssue`, `GMAIL_SEND_EMAIL`, `files.delete` into lower-case words and looks for a write verb. A write verb
// anywhere wins over a read verb (`search_and_delete` is a write). Names only, never arguments or chat content
// (R-241: no content-based decision). One list for MCP tools and Composio slugs.
import Foundation

public enum VerbClassifier {
    public enum Kind: String, Sendable, Equatable { case write, read, unknown }

    /// M7.T11 step 5 token lists (upper-case there, compared lower-case here).
    public static let writeVerbs: Set<String> = [
        "send", "create", "delete", "update", "post", "reply", "move", "archive", "remove", "add", "insert", "patch",
        "put", "upload", "share", "invite", "merge", "close", "assign",
    ]
    public static let readVerbs: Set<String> = [
        "get", "list", "search", "fetch", "read", "find", "query", "retrieve", "view", "count", "check", "download",
        "export", "lookup", "describe", "whoami", "profile", "show",
    ]

    /// The words of a tool name: snake/kebab/dot/space separated and camelCase split, lower-cased.
    public static func words(_ name: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prevLower = false
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, prevLower, !cur.isEmpty { out.append(cur); cur = "" }
                cur.append(Character(ch.lowercased()))
                prevLower = ch.isLowercase || ch.isNumber
            } else {
                if !cur.isEmpty { out.append(cur); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func classify(_ name: String) -> Kind {
        let w = words(name)
        if w.contains(where: writeVerbs.contains) { return .write }
        if w.contains(where: readVerbs.contains) { return .read }
        return .unknown
    }

    public static func isWrite(_ name: String) -> Bool { classify(name) == .write }
}
