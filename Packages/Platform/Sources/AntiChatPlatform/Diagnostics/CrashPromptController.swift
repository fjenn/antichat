// M8.T09 steps 2–4 (R-218 AC2, NFR-PR2): what happens with new crash reports at launch. Mode (Settings › Privacy &
// Data › Crash reports, key `crashReportMode`): Ask after a crash (default) → the prompt with Preview / Send /
// Don't send / Always send; Always send → the hand-off opens without the preview (the user still sends from Mail or
// the browser); Never ask → nothing. Never during onboarding (deferred, the reports stay pending). Nothing is ever
// sent without a tap: in Ask mode the hand-off runs only from `send` (the spy test counts it).
import Foundation

public enum CrashReportMode: String, Sendable, CaseIterable {
    case ask, always, never
    public static let defaultsKey = "crashReportMode"
    public static func current(_ defaults: UserDefaults) -> CrashReportMode {
        (defaults.string(forKey: defaultsKey)).flatMap(CrashReportMode.init(rawValue:)) ?? .ask
    }
}

public final class CrashPromptController: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        case prompt([CrashReport])
        case autoSend([CrashReport])
    }

    public let collector: CrashCollector
    public let defaults: UserDefaults
    public let endpoints: ReportEndpoints?
    public let handoff: ReportHandoff?

    public init(collector: CrashCollector, defaults: UserDefaults, endpoints: ReportEndpoints?, handoff: ReportHandoff?) {
        self.collector = collector; self.defaults = defaults; self.endpoints = endpoints; self.handoff = handoff
    }

    public func decide(context: CrashContext, onboardingComplete: Bool) -> Decision {
        guard onboardingComplete else { return .none }  // never during onboarding; reports stay pending
        let reports = collector.pending(context: context)
        guard !reports.isEmpty else { return .none }
        switch CrashReportMode.current(defaults) {
        case .never:
            collector.markSeen()
            return .none
        case .ask: return .prompt(reports)
        case .always:
            send(reports)
            return .autoSend(reports)
        }
    }

    /// The combined payload text of `reports` (what Preview shows and Send hands off).
    public static func payload(_ reports: [CrashReport]) -> String {
        reports.map(\.payload).joined(separator: "\n----\n")
    }

    /// Send = hand off by e-mail (payload attached), else GitHub with the payload on the clipboard.
    public func send(_ reports: [CrashReport]) {
        defer { collector.markSeen() }
        guard let handoff, let endpoints else { return }
        let text = Self.payload(reports)
        let file = collector.diagnosticsDir.appendingPathComponent("crash-report-\(Int(Date().timeIntervalSince1970)).txt")
        try? FileManager.default.createDirectory(at: collector.diagnosticsDir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file, options: .atomic)
        let report = ProblemReport(whatHappened: "AntiChat quit unexpectedly.", systemBlock: text)
        let mail = ReportProblemComposer.email(report, endpoints: endpoints, payloadFile: file)
        if !handoff.composeEmail(to: mail.recipient, subject: mail.subject, body: "AntiChat quit unexpectedly. The technical details are attached.", attachments: [file]) {
            handoff.openGitHub(ReportProblemComposer.githubURL(report, endpoints: endpoints), fullText: text)
        }
    }

    public func dontSend() { collector.markSeen() }

    public func alwaysSend(_ reports: [CrashReport]) {
        defaults.set(CrashReportMode.always.rawValue, forKey: CrashReportMode.defaultsKey)
        send(reports)
    }
}
