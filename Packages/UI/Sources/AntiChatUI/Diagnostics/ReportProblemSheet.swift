// M8.T09 step 6 (R-218 AC4; S-24): Report a problem — from Help › Report a Problem…, 👎 › Report a problem and
// About & Help. Fields: What happened (required), Steps (optional), the read-only details block (app version + build,
// macOS, chip, RAM, tier, speed class, models, catalog), "Attach the log bundle (no chats)" (on), "Include this
// chat's text" (off; only when opened from a message). [Open on GitHub] / [Email instead] hand off to the browser /
// Mail (ReportProblemComposer); AntiChat sends nothing itself. Replaces the M1.T10 shell.
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI

struct ReportProblemSheet: View {
    /// The chat's text when opened from a message (👎); nil elsewhere.
    var chatText: String? = nil
    var database: AppDatabase? = nil
    let onClose: () -> Void

    @State private var details = ""
    @State private var steps = ""
    @State private var attachLogs = true
    @State private var includeChat = false
    @State private var systemBlock = ""
    @State private var note: CopyKey?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("report.title"))
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("report.title")
            Text(CopyKey("report.body"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            field($details, CopyKey("report.placeholder"), lines: 3...6).accessibilityIdentifier("report.details")
            field($steps, CopyKey("report.steps"), lines: 2...4).accessibilityIdentifier("report.steps")
            Text(CopyKey("report.details")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
            Text(verbatim: systemBlock)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.space2)
                .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .accessibilityIdentifier("report.system")
            Toggle(isOn: $attachLogs) { Text(CopyKey("report.attachLogs")) }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("report.attachLogs")
            if chatText != nil {
                Toggle(isOn: $includeChat) { Text(CopyKey("report.includeChat")) }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("report.includeChat")
            }
            if let note { Text(note).typeStyle(.footnote).foregroundStyle(Color.textSecondary).accessibilityIdentifier("report.note") }
            HStack {
                Button(action: onClose) { Text(CopyKey("report.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("report.cancel")
                Spacer()
                if DiagnosticsCenter.shared.endpoints != nil {
                    Button { send(email: true) } label: { Text(CopyKey("report.email")) }
                        .disabled(!ready)
                        .accessibilityIdentifier("report.email")
                    Button { send(email: false) } label: { Text(CopyKey("report.github")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!ready)
                        .accessibilityIdentifier("report.github")
                } else {
                    // Release build without real endpoints yet (M10): no broken mailto / issue URL, the text to the clipboard.
                    Button {
                        Task { @MainActor in
                            let r = await report()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ReportProblemComposer.body(r), forType: .string)
                            note = CopyKey("report.copiedOnly")
                        }
                    } label: { Text(CopyKey("report.copy")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!ready)
                        .accessibilityIdentifier("report.copy")
                }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 480)
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reportSheet")
        .task {
            let db = database
            let center = DiagnosticsCenter.shared
            systemBlock = await center.liveSystemReport(database: db).text()
        }
    }

    private var ready: Bool { !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !systemBlock.isEmpty }

    private func field(_ text: Binding<String>, _ placeholder: CopyKey, lines: ClosedRange<Int>) -> some View {
        TextField(text: text, axis: .vertical) { Text(placeholder) }
            .textFieldStyle(.plain)
            .typeStyle(.body)
            .lineLimit(lines)
            .padding(Spacing.space2)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    func report() async -> ProblemReport {
        var logs: URL?
        if attachLogs {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(LogBundleBuilder.fileName())
            if (try? await DiagnosticsCenter.shared.buildLogBundle(to: url, includeContent: false, database: database)) != nil { logs = url }
        }
        return ProblemReport(whatHappened: details, steps: steps, systemBlock: systemBlock,
                             chatText: includeChat ? chatText : nil, logBundle: logs)
    }

    private func send(email: Bool) {
        guard let endpoints = DiagnosticsCenter.shared.endpoints else { return }
        Task { @MainActor in await send(email: email, endpoints: endpoints) }
    }

    private func send(email: Bool, endpoints: ReportEndpoints) async {
        let r = await report()
        let handoff = DiagnosticsCenter.shared.handoff
        if email {
            let m = ReportProblemComposer.email(r, endpoints: endpoints, payloadFile: nil)
            if handoff.composeEmail(to: m.recipient, subject: m.subject, body: m.body, attachments: m.attachments) {
                onClose()
            } else {
                note = CopyKey("report.noEmail")
            }
        } else {
            handoff.openGitHub(ReportProblemComposer.githubURL(r, endpoints: endpoints), fullText: ReportProblemComposer.body(r))
            note = CopyKey("report.copied")
            // The issue body says the log bundle is attached separately: show it so it can be dragged in (review fix).
            if let logs = r.logBundle { NSWorkspace.shared.activateFileViewerSelecting([logs]) }
        }
    }
}
