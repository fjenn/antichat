// UntrustedContextRule (M7.T15; NFR-SEC5, K-051, K-NEW-FILES-10): when is untrusted content in a turn's context, so
// that a write/send/delete call asks first (`approve.untrusted`) even under "Always allow" (PermissionMatrix)?
//   - a result of a tool whose output is untrusted (web, MCP, Composio, files, skills) earlier in this turn
//     (ToolLoopState.untrusted, set after each such call), or in the reply being continued (`resume`);
//   - a skill body in the prompt (explicit chip, Apply to every chat, pre-load): the same text `load_skill` returns
//     as untrusted output, so it counts the same (imported skills are third-party text);
//   - an uploaded file in the conversation: the prompt layer puts its text (document, excerpts, OCR text, image
//     caption, sheet tables) inside an `<… untrusted="true">` wrapper (UntrustedText.wrappers) in the user message.
// The rule looks only for those wrappers (provenance labels the app itself writes), never at what the content says:
// it is a provenance label plus a confirmation and decides nothing from content (R-241; r241-allowlist).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public enum UntrustedContextRule {
    private static let opening = try! NSRegularExpression(
        pattern: "<(?:" + UntrustedText.wrappers.joined(separator: "|") + ")\\b[^>]*\\buntrusted=\"true\"",
        options: [.caseInsensitive])

    /// True when a user message of `conversation` carries an untrusted wrapper (an uploaded file's content).
    public static func conversationIsUntrusted(_ conversation: [ChatMessage]) -> Bool {
        conversation.contains { m in
            guard m.role == .user, m.content.contains("untrusted=") else { return false }
            let ns = m.content as NSString
            return opening.firstMatch(in: m.content, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }

    private static let wrapped = try! NSRegularExpression(
        pattern: "<(" + UntrustedText.wrappers.joined(separator: "|") + ")\\b[^>]*\\buntrusted=\"true\"[^>]*>[\\s\\S]*?</\\1\\s*>",
        options: [.caseInsensitive])

    /// M7.T16 review #5: `read_url` sends its URL (query string included) to that host, so under untrusted context a
    /// page or tool result could use it to carry the conversation out. The call asks first (`approve.untrusted`) unless
    /// the URL's host is one the user wrote in their own words (uploaded-file wrappers do not count). A provenance
    /// check on where the URL came from, like the rule above; it never reads what the content says (R-241).
    ///
    /// M7 bars-2 (S1: 3/100 T3 web answers never came back): a URL that is exactly one of the turn's own search
    /// results (`resultURLs`, the harness-recorded source list, compared without fragment, `www.` or a trailing slash,
    /// query included) does not ask: its whole text was fixed by the search engine before the model saw anything, so
    /// the model cannot have put conversation data into it (the search queries it wrote already went out the same way).
    /// The T3 model often reads a result page in full after the forced web step; the card then held the answer until
    /// the user approved a page of their own search (the headless bench never answered it: the "hang").
    public static func readURLNeedsConfirmation(argumentsJSON: String, conversation: [ChatMessage],
                                                resultURLs: [String] = []) -> Bool {
        guard let d = argumentsJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = o["url"] as? String,
              var host = URL(string: s.trimmingCharacters(in: .whitespaces))?.host()?.lowercased(), !host.isEmpty else { return true }
        if let key = urlKey(s), resultURLs.contains(where: { urlKey($0) == key }) { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return !conversation.contains { m in
            guard m.role == .user else { return false }
            let ns = m.content as NSString
            let own = wrapped.stringByReplacingMatches(in: m.content, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            return own.lowercased().contains(host)
        }
    }

    /// The comparable form of a URL: lowercased scheme and host without `www.`, path without a trailing slash, the
    /// query kept verbatim, no fragment. nil = not an http(s) URL.
    static func urlKey(_ s: String) -> String? {
        guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        c.fragment = nil
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = c.port.map { ":\($0)" } ?? ""
        return host + port + path + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// True when the turn's prompt carries skill bodies (stable layer or pre-loaded), not just the manifest.
    public static func skillBodiesInPrompt(_ plan: SkillTurnPlan?) -> Bool {
        guard let plan else { return false }
        return !plan.active.isEmpty || !plan.preloaded.isEmpty
    }
}
