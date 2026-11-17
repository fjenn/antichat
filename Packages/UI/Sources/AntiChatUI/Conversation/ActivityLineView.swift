// ActivityLine (components.md §3; M1.T16 step 5; IS-12): one collapsible line per tool call of a reply.
// running → `status.tool` ("Using {tool}") + live seconds · done → `act.tool` ("Used {tool}"); a line that has something
// a person can read (the search's queries and pages, the picture's prompt, a table query's rows, what was remembered)
// has a ▸ that shows it — never the call's raw arguments or result (JSON, ids, file paths) · failed → danger icon + `act.failed` · denied → `tool.denied` ·
// skipped (duplicate) → `act.tool.skipped` · awaiting approval → `status.tool` (the ApprovalCard sits below).
// The loop-limit notice (`tool.loopLimit` + [Continue]) is `LoopLimitNotice`.
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import SwiftUI

public struct ActivityLineView: View {
    let activity: ToolActivity
    /// M6.T09: [Try again] on a failed file-out card (re-runs the turn).
    let onTryAgain: (() -> Void)?
    /// M6.T20: the chat's database (Office edit offer → install) and [Re-create the file] (regenerate with steering).
    let database: AppDatabase?
    let onRecreate: (() -> Void)?
    /// M7.T12: "Turn off for this chat" on a skill line (the skill's name).
    let onTurnOffSkill: ((String) -> Void)?
    /// M7.T13 (R-264): [Install] on a SkillInstallCard (the draft's JSON); nil result = installed.
    let onInstallSkill: ((String) -> String?)?
    /// The Connect card connected its app and answered a request: run that request again.
    let onConnected: (() -> Void)?
    /// The reply holding this call (M4.T16: with the call id, the key of its media job — call ids repeat per reply).
    let messageID: String?
    @State private var expanded = false
    /// A-M6-T21a (a): this run_python / edit_office_file call waits for a free File tools slot.
    @State private var sandboxWaiting = false

    public init(activity: ToolActivity, onTryAgain: (() -> Void)? = nil, database: AppDatabase? = nil,
                onRecreate: (() -> Void)? = nil, onTurnOffSkill: ((String) -> Void)? = nil,
                onInstallSkill: ((String) -> String?)? = nil, onConnected: (() -> Void)? = nil, messageID: String? = nil) {
        self.onConnected = onConnected
        self.activity = activity
        self.messageID = messageID
        self.onTryAgain = onTryAgain
        self.database = database
        self.onRecreate = onRecreate
        self.onTurnOffSkill = onTurnOffSkill
        self.onInstallSkill = onInstallSkill
    }

    /// `web_search` → "Web search", `get_time` → "Get time" (snake_case tool id, first letter capitalised).
    static func readableName(_ tool: String) -> String {
        if tool == RunPythonTool.name { return CopyText(CopyKey("set.tools.code")).string }  // "Analyse data"
        let words = tool.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private var label: CopyText {
        if sandboxWaiting, isRunning, RunPythonActivity.usesSandbox(activity) { return CopyText(CopyKey("sandbox.waiting")) }
        if QueryActivity.isQuery(activity), let q = QueryActivity.label(activity) { return q }  // M6.T08
        if RunPythonActivity.isRun(activity), let r = RunPythonActivity.label(activity) { return r }  // M6.T19
        if FileOutActivity.isFileOut(activity), let f = FileOutActivity.label(activity) { return f }  // M6.T09
        if ChartActivity.isChart(activity), let c = ChartActivity.label(activity) { return c }  // M6.T12
        if SearchActivity.isSearch(activity), let w = SearchActivity.label(activity) { return w }  // M7.T03
        if MemoryNotice.isMemory(activity), let m = MemoryNotice.label(activity) { return m }  // M8.T03
        // A connected app (Composio): the app and what is happening, never "Composio" or a slug.
        if let k = ConnectedAppActivity.kind(activity) {
            switch (k, activity.state) {
            case (.lookup, .running), (.lookup, .awaitingApproval): return CopyText(CopyKey("act.apps.checking"))
            case (.lookup, .failed): return CopyText(CopyKey("act.failed"), ["action": CopyText(CopyKey("add.connections")).string])
            case (.lookup, _): return CopyText(CopyKey("act.apps.checked"))
            case (.app(let app, let reads), .running), (.app(let app, let reads), .awaitingApproval):
                return reads ? CopyText(CopyKey("act.app.checking"), ["app": app]) : CopyText(CopyKey("status.tool"), ["tool": app])
            case (.app(let app, let reads), .done):
                return CopyText(CopyKey(reads ? "act.app.checked" : "act.connection"), ["app": app])
            case (.app(let app, _), .failed): return CopyText(CopyKey("act.failed"), ["action": app])
            case (.app(let app, _), .denied): return CopyText(CopyKey("tool.denied"), ["action": app])  // hidden (isHidden)
            case (.app(let app, _), .skipped): return CopyText(CopyKey("act.tool.skipped"), ["tool": app])
            }
        }
        // M7.T06 step 7 (R-081 AC3): a connection's tool reads "Used {app}" once done.
        if activity.state == .done, let app = MCPTools.appName(forTool: activity.tool) { return CopyText(CopyKey("act.connection"), ["app": app]) }
        // M9.T08: people read a name, not a tool id ("web_search didn't work" → "Web search didn't work"); a
        // connection's tool reads as its app.
        let tool = MCPTools.appName(forTool: activity.tool) ?? Self.readableName(activity.tool)
        switch activity.state {
        // A connected app is named ("Using Slack"); a built-in step has no name a person knows: "Working on it…".
        case .running, .awaitingApproval:
            return MCPTools.appName(forTool: activity.tool) != nil ? CopyText(CopyKey("status.tool"), ["tool": tool])
                : CopyText(CopyKey("status.verb.2"))
        // "Created …" only for a finished picture / clip: a call that ended unavailable, failed, withheld or not
        // started is `.done` as a tool call too, and its card says what happened.
        case .done where ImageJobActivity.isImage(activity) && Self.mediaFinished(activity):
            return CopyText(CopyKey(activity.tool == EditImageTool.name ? "act.image.edited" : "act.image.done"))
        case .done where VideoJobActivity.isVideo(activity) && Self.mediaFinished(activity): return CopyText(CopyKey("act.video.done"))
        case .done: return CopyText(CopyKey("act.tool"), ["tool": tool])
        // VQ r65 (S-11): a failed picture / video call says so once, on its card (failure line + Retry); the line
        // above it only names the tool (it read "Create image didn't work. Retry" over "couldn't be made · Retry").
        case .failed where showsMediaCard: return CopyText(CopyKey("act.tool"), ["tool": tool])
        case .failed: return CopyText(CopyKey("act.failed"), ["action": tool])
        case .denied: return CopyText(CopyKey("tool.denied"), ["action": tool])
        case .skipped: return CopyText(CopyKey("act.tool.skipped"), ["tool": tool])
        }
    }

    /// The media call's result is a finished picture / clip (`{"status":"done"}`), not just a finished call.
    static func mediaFinished(_ a: ToolActivity) -> Bool {
        guard let r = a.result else { return false }
        if case .done? = ImageTurnPolicy.Outcome.parse(r) { return true }
        if case .done? = VideoTurnPolicy.Outcome.parse(r) { return true }
        return false
    }

    private var isRunning: Bool { activity.state == .running || activity.state == .awaitingApproval }

    /// The prompt a picture or clip was made from (the readable detail of a finished media line).
    static func mediaPrompt(_ a: ToolActivity) -> String? {
        guard ImageJobActivity.isImage(a) || VideoJobActivity.isVideo(a),
              let o = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any],
              let p = (o["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }

    /// What ▸ shows for a line. Only things a person can read: a line with none has no ▸ at all.
    enum Detail: Equatable { case memory, query, search, prompt(String) }

    static func detail(_ a: ToolActivity) -> Detail? {
        guard a.state != .running, a.state != .awaitingApproval else { return nil }
        if MemoryNotice.isMemory(a) { return MemoryNotice.eventIDs(a).isEmpty ? nil : .memory }
        if QueryActivity.isQuery(a) { return a.state == .done && !QueryActivity.rows(a).header.isEmpty ? .query : nil }
        if SearchActivity.isSearch(a) {
            return SearchActivity.queries(a).isEmpty && SearchActivity.sources(a).isEmpty ? nil : .search
        }
        if a.state == .done, mediaFinished(a), let p = mediaPrompt(a) { return .prompt(p) }
        return nil
    }

    /// One status at a time: while a picture or clip is being made its card says so ("Creating image… 40%"), and a
    /// second line above it ("Using Create image 4 s") said the same thing in tool words.
    private var hidesHeader: Bool {
        if FileOutActivity.isFileOut(activity) && activity.state == .done && FileOutActivity.item(activity) != nil { return true }
        return showsMediaCard && isRunning
    }

    /// The call draws an image or video job card under its line (the card carries the outcome and its action).
    private var showsMediaCard: Bool { ImageJobActivity.isImage(activity) || VideoJobActivity.isVideo(activity) }

    /// A media call whose pack is missing: the install card under the reply is its whole answer (M2.T24 step 4), so it
    /// has no line — `act.tool.skipped` ("Skipped a repeated … call") was wrong for it (M4.T16 Release run).
    static func isHidden(_ a: ToolActivity) -> Bool {
        (a.kind == .tool && a.state == .skipped && a.result == InstallCardPolicy.packNotInstalled)
            || ConnectedAppActivity.isHidden(a)
            // Plumbing a person has no use for once it is over: loading tools, and looking through the connected
            // apps' actions (the line that follows names the app that was actually used).
            || (a.state == .done && (a.tool == "find_tools" || { if case .lookup = ConnectedAppActivity.kind(a) { true } else { false } }()))
            // A connected app's denied action: the reply's own sentence ("OK, I didn't do that…") says it once.
            || (a.state == .denied && ConnectedAppActivity.kind(a) != nil)
    }

    /// One line per failed step: when a step failed, the same tool failing again right after it (the model's own
    /// retries, or its repeated call being skipped) adds no line. It read "… didn't work. Retry" three times.
    static func collapsingRepeatedFailures(_ activities: [ToolActivity]) -> [ToolActivity] {
        var out: [ToolActivity] = []
        var failedTool: String?  // the tool of the failed line last shown, until another visible line follows it
        for a in activities {
            if isHidden(a) { out.append(a); continue }
            let repeats = a.kind == .tool && (a.state == .failed || a.state == .skipped)
            if repeats, a.tool == failedTool { continue }
            failedTool = a.kind == .tool && a.state == .failed ? a.tool : nil
            out.append(a)
        }
        return out
    }

    public var body: some View {
        if Self.isHidden(activity) { EmptyView() }
        else if activity.kind == .notice { ActivityNoticeView(activity: activity) }
        else if activity.kind == .skill { SkillActivityLine(activity: activity, onTurnOff: onTurnOffSkill) }  // M7.T12
        else if activity.kind == .skillCard { SkillInstallCard(activity: activity, onInstall: onInstallSkill) }  // M7.T13
        else if activity.kind == .connectCard { ConnectCardView(activity: activity, onConnected: onConnected) }
        else { line }
    }

    private var line: some View {
        let detail = Self.detail(activity)
        return VStack(alignment: .leading, spacing: Spacing.space1) {
            // A created file is its card: "Created Budget.xlsx" above a card that says Budget.xlsx is said twice.
            if !hidesHeader {
            Button {
                guard detail != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.space2) {
                    if activity.state == .failed, !showsMediaCard {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.danger)
                    } else if isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: QueryActivity.isQuery(activity) ? "tablecells"
                              : SearchActivity.isSearch(activity) ? "globe"
                              : FileOutActivity.isFileOut(activity) ? "doc.badge.plus"
                              : ChartActivity.isChart(activity) ? "chart.bar.xaxis"
                              : MemoryNotice.isMemory(activity) ? "brain"
                              : ImageJobActivity.isImage(activity) ? "photo"
                              : VideoJobActivity.isVideo(activity) ? "film"
                              : MCPTools.appName(forTool: activity.tool) != nil ? "puzzlepiece.extension" : "wrench.and.screwdriver")
                            .foregroundStyle(Color.textSecondary)
                    }
                    Text(label)
                        .typeStyle(.subhead)
                        .foregroundStyle(Color.textSecondary)
                    if activity.state == .awaitingApproval {
                        EmptyView()  // waiting for the user's answer is not the call taking long: no seconds
                    } else if isRunning {
                        TimelineView(.periodic(from: activity.startedAt, by: 1)) { ctx in
                            Text(verbatim: "\(Int(max(0, ctx.date.timeIntervalSince(activity.startedAt)))) s")
                                .typeStyle(.subhead)
                                .foregroundStyle(Color.textTertiary)
                                .monospacedDigit()
                        }
                    } else if detail != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(detail != nil)
            .accessibilityIdentifier("activityLine")
            .accessibilityValue(Text(verbatim: activity.state.rawValue))
            .probeAnchor("activityLine-\(activity.id)")
            .onAppear { sandboxWaiting = RunPythonActivity.isWaiting(activity) }
            .onReceive(NotificationCenter.default.publisher(for: FileToolsSlots.waitingDidChange).receive(on: DispatchQueue.main)) { _ in
                sandboxWaiting = RunPythonActivity.isWaiting(activity)
            }
            }
            if expanded, !hidesHeader, let detail {
                Group {
                    switch detail {
                    case .memory: MemoryNoticeView(eventIDs: MemoryNotice.eventIDs(activity))  // M8.T03
                    case .query: QueryActivityDetail(activity: activity)
                    case .search: SearchActivityDetail(activity: activity)  // M7.T03
                    case .prompt(let prompt):
                        Text(verbatim: prompt)
                            .typeStyle(.caption)
                            .foregroundStyle(Color.textTertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("activityDetail")
                    }
                }
                .padding(.leading, Spacing.space5)
            }
            if SearchActivity.failedAllEngines(activity), let onTryAgain {
                // M7.T03 step 9: [Retry search] re-runs the turn (the answer above went on without the web).
                Button(action: onTryAgain) { Text(CopyKey("search.retry")) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.leading, Spacing.space5)
                    .probeID("searchRetry")
            }
            if RunPythonActivity.summary(activity)?.linksToSettings == true {
                Button(action: { SettingsPresenter.shared.show(.tools, row: "codeNet") }) { Text(CopyKey("side.settings")) }
                    .accessibilityIdentifier("side.settings")
                    .buttonStyle(.link).padding(.leading, Spacing.space5)
            }
            if ImageJobActivity.isImage(activity) {
                ImageJobActivityCard(activity: activity, onTryAgain: onTryAgain, messageID: messageID)  // M4.T08
            } else if VideoJobActivity.isVideo(activity) {
                VideoJobActivityCard(activity: activity, onTryAgain: onTryAgain, messageID: messageID)  // M5.T10
            } else if OfficeEditActivity.isEdit(activity), let offer = OfficeEditActivity.offer(activity) {
                OfficeEditOfferCard(offer: offer, database: database, onRecreate: onRecreate)  // M6.T20
            } else if RunPythonActivity.isRun(activity) {
                RunPythonOutputCards(activity: activity)
            } else if FileOutActivity.isFileOut(activity) {
                FileOutActivityCard(activity: activity, onTryAgain: onTryAgain)  // M6.T09
            } else if ChartActivity.isChart(activity) {
                ChartActivityCard(activity: activity)  // M6.T12
            }
        }
    }
}

/// `tool.loopLimit` ("Stopped after several steps.") with [Continue] (a fresh step budget, M1.T16 step 6).
public struct LoopLimitNotice: View {
    let enabled: Bool
    /// The answer stopped at the output limit (`tool.lengthLimit`), not the step limit.
    let lengthLimit: Bool
    let onContinue: () -> Void

    public init(enabled: Bool = true, lengthLimit: Bool = false, onContinue: @escaping () -> Void) {
        self.enabled = enabled
        self.lengthLimit = lengthLimit
        self.onContinue = onContinue
    }

    public var body: some View {
        HStack(spacing: Spacing.space3) {
            Text(CopyText(CopyKey(lengthLimit ? "tool.lengthLimit" : "tool.loopLimit")))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("loopLimitMessage")
            Button(action: onContinue) { Text(CopyText(CopyKey("tool.loopLimit.continue"))) }
                .buttonStyle(.bordered)
                .disabled(!enabled)
                .accessibilityIdentifier("loopLimitContinue")
                .probeID("loopLimitContinue")
        }
        .accessibilityElement(children: .contain)
        .probeID("loopLimitNotice")
    }
}

#Preview("ActivityLine") {
    VStack(alignment: .leading, spacing: Spacing.space3) {
        ActivityLineView(activity: ToolActivity(id: "1", tool: "get_time", state: .running))
        ActivityLineView(activity: ToolActivity(id: "2", tool: "echo", state: .done, argumentsJSON: #"{"text":"hi"}"#, result: "hi", seconds: 0.1))
        ActivityLineView(activity: ToolActivity(id: "3", tool: "write_note", state: .denied))
        ActivityLineView(activity: ToolActivity(id: "4", tool: "echo", state: .failed, result: "bad arguments"))
        ActivityLineView(activity: ToolActivity(id: "5", tool: "query_data", state: .done,
                                                argumentsJSON: #"{"sql":"SELECT region, sum(amount) FROM Transactions GROUP BY 1"}"#,
                                                result: #"{"columns":["region","sum"],"data_ref":"qr_1","elapsed_ms":4,"file":"budget.xlsx","row_count":2,"truncated":false,"types":["VARCHAR","DOUBLE"]}"# + "\n| region | sum |\n| --- | --- |\n| North | 10.5 |\n| South | 7 |\n"))
        LoopLimitNotice(onContinue: {})
    }
    .padding(Spacing.space7)
    .frame(width: 560)
    .background(Color.surfaceCanvas)
}
