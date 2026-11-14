// M8.T09 steps 4, 6 (R-218 AC2/AC4): hand a problem report or crash payload to the user's own channel. AntiChat sends
// nothing itself (no crash server; the NetworkGate `crash-report` category stays unused): GitHub opens
// `<IssuesURL>/new?template=bug.yml&title=…&body=…` in the browser (body ≤ 6 KB, URL ≤ 8 KB; the full text goes to the
// pasteboard), Email opens the user's mail client with the payload attached (`NSSharingService.composeEmail`, done
// by the UI). The endpoints come from `Config/Endpoints.plist` (`IssuesURL`, `SupportEmail`).
import AntiChatStorage
import Foundation

public struct ReportEndpoints: Sendable, Equatable {
    public var issuesURL: URL
    public var supportEmail: String

    public init(issuesURL: URL, supportEmail: String) { self.issuesURL = issuesURL; self.supportEmail = supportEmail }

    /// `allowPlaceholders` = DEBUG (tests read the placeholder values). A release build treats a placeholder or a
    /// malformed value as "not configured" (nil): the sheets then offer Copy instead of a broken mailto / issue URL.
    public static func load(plist url: URL, allowPlaceholders: Bool = AppDatabaseFlags.isDebugBuild) -> ReportEndpoints? {
        guard let d = NSDictionary(contentsOf: url), let issuesText = d["IssuesURL"] as? String,
              let mail = d["SupportEmail"] as? String, let issues = URL(string: issuesText) else { return nil }
        guard allowPlaceholders || (isUsableIssuesURL(issues) && isUsableEmail(mail)) else { return nil }
        return ReportEndpoints(issuesURL: issues, supportEmail: mail)
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> ReportEndpoints? {
        bundle.url(forResource: "Endpoints", withExtension: "plist").flatMap { load(plist: $0) }
    }

    /// Placeholder markers of Config/Endpoints.plist until M10 (`tools/ci/endpoints-check.py` keeps both lists equal).
    public static let placeholderMarkers = ["placeholder", ".invalid", "example.", "localhost", "todo", "changeme"]

    public static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.isEmpty || placeholderMarkers.contains { l.contains($0) }
    }

    /// https, a real-looking host, not a placeholder.
    public static func isUsableIssuesURL(_ u: URL) -> Bool {
        guard u.scheme == "https", let host = u.host, host.contains("."), !isPlaceholder(u.absoluteString) else { return false }
        return true
    }

    /// one `@`, a dotted domain, no spaces, not a placeholder.
    public static func isUsableEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !s.contains(" "), !isPlaceholder(s) else { return false }
        return true
    }
}

public struct ProblemReport: Sendable, Equatable {
    public var whatHappened: String
    public var steps: String
    /// The read-only prefilled block (app, macOS, chip, RAM, tier, speed class, models, catalog).
    public var systemBlock: String
    /// Only when the user ticked "Include this chat's text".
    public var chatText: String?
    public var logBundle: URL?

    public init(whatHappened: String, steps: String = "", systemBlock: String, chatText: String? = nil, logBundle: URL? = nil) {
        self.whatHappened = whatHappened; self.steps = steps; self.systemBlock = systemBlock; self.chatText = chatText
        self.logBundle = logBundle
    }
}

public enum ReportProblemComposer {
    public static let maxBodyBytes = 6 * 1024
    public static let maxURLBytes = 8 * 1024

    /// GitHub issue-form body (bug.yml fields: summary, steps, expected/actual left to the form, versions block).
    public static func body(_ r: ProblemReport) -> String {
        var s = "### What happened\n\n\(r.whatHappened)\n"
        if !r.steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s += "\n### Steps\n\n\(r.steps)\n" }
        s += "\n### Versions\n\n```\n\(r.systemBlock)\n```\n"
        if let chat = r.chatText, !chat.isEmpty { s += "\n### Chat\n\n\(chat)\n" }
        if r.logBundle != nil { s += "\n(The log bundle is attached separately.)\n" }
        return s
    }

    static func title(_ r: ProblemReport) -> String {
        let first = r.whatHappened.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Problem report"
        return String(first.prefix(80))
    }

    /// The issue URL (body cut to `maxBodyBytes` at a character boundary; the whole URL ≤ `maxURLBytes`).
    public static func githubURL(_ r: ProblemReport, endpoints: ReportEndpoints) -> URL {
        var body = body(r)
        func make(_ b: String) -> URL {
            var c = URLComponents(url: endpoints.issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "template", value: "bug.yml"), URLQueryItem(name: "title", value: title(r)),
                            URLQueryItem(name: "body", value: b)]
            return c.url!
        }
        let note = "\n…(cut; the full report is on the clipboard)"
        if body.utf8.count > maxBodyBytes { body = cut(body, to: maxBodyBytes - note.utf8.count) + note }
        var url = make(body)
        while url.absoluteString.utf8.count > maxURLBytes, body.count > note.count {
            body = cut(body, to: body.utf8.count * 3 / 4) + note
            url = make(body)
        }
        return url
    }

    static func cut(_ s: String, to bytes: Int) -> String {
        var out = ""
        var n = 0
        for ch in s {
            n += ch.utf8.count
            if n > bytes { break }
            out.append(ch)
        }
        return out
    }

    /// The e-mail hand-off: subject, body and attachments (the payload file and the optional log bundle).
    public static func email(_ r: ProblemReport, endpoints: ReportEndpoints, payloadFile: URL?) -> (recipient: String, subject: String, body: String, attachments: [URL]) {
        (endpoints.supportEmail, "AntiChat: \(title(r))", body(r), [payloadFile, r.logBundle].compactMap { $0 })
    }
}

/// Who actually hands a report to Mail / the browser (the UI's NSSharingService + NSWorkspace; a spy in tests).
public protocol ReportHandoff: AnyObject, Sendable {
    func openGitHub(_ url: URL, fullText: String)
    func composeEmail(to: String, subject: String, body: String, attachments: [URL]) -> Bool
}
