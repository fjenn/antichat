// M8.T09 steps 4, 6 (R-218 AC2/AC4): hand a problem report or crash payload to the user's own channel. AntiChat sends
// nothing itself (no crash server; the NetworkGate `crash-report` category stays unused): GitHub opens
// `<IssuesURL>/new?template=bug.yml&title=…&body=…` in the browser (body ≤ 6 KB, URL ≤ 8 KB; the full text goes to the
// pasteboard), Email opens the user's mail client with the payload attached (`NSSharingService.composeEmail`, done
// by the UI). The endpoints come from `Config/Endpoints.plist` (`IssuesURL`, `SupportEmail`).
// Files and screenshots the user attaches (`ReportAttachments`: ≤ 5 items, ≤ 15 MB together) ride along the same two
// ways: Mail gets them as attachments; a GitHub issue URL cannot carry files, so the UI shows them in Finder to drag in.
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
    /// Files and screenshots the user attached (already within `ReportAttachments`' limits).
    public var attachments: [URL]

    public init(whatHappened: String, steps: String = "", systemBlock: String, chatText: String? = nil, logBundle: URL? = nil,
                attachments: [URL] = []) {
        self.whatHappened = whatHappened; self.steps = steps; self.systemBlock = systemBlock; self.chatText = chatText
        self.logBundle = logBundle; self.attachments = attachments
    }
}

/// One file the user attached to a problem report.
public struct ReportAttachment: Sendable, Equatable, Identifiable {
    public var url: URL
    public var bytes: Int64
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, bytes: Int64) { self.url = url; self.bytes = bytes }
}

/// The limits of what a report can carry: Mail is the only channel that takes files, and mail servers commonly stop
/// at 25 MB per message after encoding (+ 37%), so 15 MB of files leaves room for the log bundle.
public enum ReportAttachments {
    public static let maxCount = 5
    public static let maxTotalBytes: Int64 = 15 * 1024 * 1024

    public enum Refusal: Sendable, Equatable {
        /// More than `maxCount` items.
        case tooMany
        /// This file would take the total over `maxTotalBytes`.
        case tooLarge(name: String)
        /// A folder, or a file that cannot be read.
        case unreadable(name: String)
    }

    public struct Outcome: Sendable, Equatable {
        public var items: [ReportAttachment]
        /// The first thing that was left out, to tell the user (nil: everything was added).
        public var refusal: Refusal?
    }

    /// A readable regular file with its size; nil for a folder, a missing or an unreadable file.
    public static func measure(_ url: URL) -> ReportAttachment? {
        let u = url.standardizedFileURL
        guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]),
              v.isRegularFile == true, v.isReadable != false, let size = v.fileSize else { return nil }
        return ReportAttachment(url: u, bytes: Int64(size))
    }

    /// `current` plus the files at `urls`, in order, as far as the limits allow. A file already attached is skipped
    /// without a message; a file that does not fit is left out and a smaller one after it can still be added.
    public static func add(_ urls: [URL], to current: [ReportAttachment],
                           measure: (URL) -> ReportAttachment? = ReportAttachments.measure) -> Outcome {
        var out = Outcome(items: current, refusal: nil)
        var total = current.reduce(Int64(0)) { $0 + $1.bytes }
        for url in urls {
            guard let item = measure(url) else {
                if out.refusal == nil { out.refusal = .unreadable(name: url.lastPathComponent) }
                continue
            }
            if out.items.contains(where: { $0.url == item.url }) { continue }
            if out.items.count >= maxCount {
                if out.refusal == nil { out.refusal = .tooMany }
                break
            }
            if total + item.bytes > maxTotalBytes {
                if out.refusal == nil { out.refusal = .tooLarge(name: item.name) }
                continue
            }
            out.items.append(item)
            total += item.bytes
        }
        return out
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
        // A count only: file names can be private and an issue is public.
        if !r.attachments.isEmpty { s += "\n(\(r.attachments.count) more attachment(s) from the reporter, added separately.)\n" }
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

    /// The e-mail hand-off: subject, body and attachments (the payload file, the optional log bundle, the user's files).
    public static func email(_ r: ProblemReport, endpoints: ReportEndpoints, payloadFile: URL?) -> (recipient: String, subject: String, body: String, attachments: [URL]) {
        (endpoints.supportEmail, "AntiChat: \(title(r))", body(r), [payloadFile, r.logBundle].compactMap { $0 } + r.attachments)
    }
}

/// Who actually hands a report to Mail / the browser (the UI's NSSharingService + NSWorkspace; a spy in tests).
public protocol ReportHandoff: AnyObject, Sendable {
    func openGitHub(_ url: URL, fullText: String)
    func composeEmail(to: String, subject: String, body: String, attachments: [URL]) -> Bool
}
