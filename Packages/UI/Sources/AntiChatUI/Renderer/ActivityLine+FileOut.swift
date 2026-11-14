// M6.T09 step 9 / M6.T10 (R-273 AC1/AC2/AC4): the `create_document` / `create_spreadsheet` / `export_table` step on the ActivityLine and its FileCard. Running →
// `act.creating` ("Creating {filename}…") + a generating card; done → `act.created` + the ready card (path, size and
// version from the result's JSON summary line, so a reloaded chat shows the same card); failed (the validator error after
// the one repair turn, or a render error) → the error card with `file.createFailed` and [Try again] (re-runs the turn),
// the activity line keeps the validator message. M6.T13: a click opens the window's side panel (Space keeps Quick
// Look); a file produced in this session opens the panel by itself once (R-275 step 4, R-016 AC1), a reloaded chat
// does not.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI
import UniformTypeIdentifiers

enum FileOutActivity {
    static let tools: Set<String> = [CreateDocumentTool.name, CreateSpreadsheetTool.name, ExportTableTool.name,
                                      CreatePresentationTool.name, EditOfficeFileTool.name]

    static func isFileOut(_ a: ToolActivity) -> Bool { tools.contains(a.tool) && a.kind == .tool }

    /// The file name the call is making (from its arguments; the result once done).
    static func filename(_ a: ToolActivity) -> String {
        if let r = a.result.flatMap(FileOutResult.parse) { return r.file }
        if a.tool == RunPythonTool.name { return RunPythonActivity.purpose(a) }
        if a.tool == EditOfficeFileTool.name,  // M6.T20: the attached file's own name
           let o = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any],
           let f = o["file"] as? String { return f }
        if a.tool == CreateDocumentTool.name, let spec = try? CreateDocumentTool.decode(a.argumentsJSON) { return spec.filename }
        // Spreadsheets / exports: `filename` + the format's extension.
        if let o = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any],
           let name = o["filename"] as? String {
            let ext = a.tool == CreatePresentationTool.name ? "pptx"
                : (o["format"] as? String) ?? ((name as NSString).pathExtension.lowercased() == "csv" ? "csv" : "xlsx")
            let base = (name as NSString).pathExtension.lowercased() == ext ? (name as NSString).deletingPathExtension : name
            return FileOutNames.filename(title: base, ext: ext)
        }
        return "file"
    }

    static func label(_ a: ToolActivity) -> CopyText? {
        switch a.state {
        case .running, .awaitingApproval: CopyText(CopyKey("act.creating"), ["filename": filename(a)])
        case .done where OfficeEditActivity.offer(a) != nil: nil  // M6.T20: nothing was created; the offer card explains
        case .done: CopyText(CopyKey("act.created"), ["filename": filename(a)])
        default: nil
        }
    }

    /// The version chain of a done call (version 2 and later; M6.T10 R-273 AC4), oldest first.
    static func versions(_ a: ToolActivity) -> [VersionInfo] {
        guard a.state == .done, let r = a.result.flatMap(FileOutResult.parse), let v = r.versions, v.count > 1 else { return [] }
        return v
    }

    /// The panel versions of a done call (the whole chain for v2+), oldest first.
    static func panelVersions(_ a: ToolActivity) -> [PanelVersion] {
        guard a.state == .done, let r = a.result.flatMap(FileOutResult.parse) else { return [] }
        let chain = versions(a)
        if chain.count > 1 { return chain.map { PanelVersion(n: $0.n, url: URL(fileURLWithPath: $0.path)) } }
        return [PanelVersion(n: r.version, url: URL(fileURLWithPath: r.path))]
    }

    /// A call that finished moments ago in this session (not a chat reloaded from disk): the panel opens by itself.
    static func isFresh(_ a: ToolActivity, now: Date = Date()) -> Bool {
        a.state == .done && now.timeIntervalSince(a.startedAt) - (a.seconds ?? 0) < 15
    }

    /// The card for the activity, or nil (denied / skipped).
    static func item(_ a: ToolActivity) -> FileCardItem? {
        let name = filename(a)
        switch a.state {
        case .running, .awaitingApproval:
            return FileCardItem(url: URL(fileURLWithPath: "/dev/null/\(name)"), displayName: name, size: 0,
                                state: .generating(progress: nil))
        case .done:
            guard let r = a.result.flatMap(FileOutResult.parse) else { return nil }
            return FileCardItem(url: URL(fileURLWithPath: r.path), displayName: r.file, size: r.size, version: r.version)
        case .failed:
            return FileCardItem(url: URL(fileURLWithPath: "/dev/null/\(name)"), displayName: name, size: 0,
                                state: .error(reason: CopyKey("file.createFailed")))
        default:
            return nil
        }
    }
}

/// The FileCard under a file-out activity (a new card per state of the call, so the view model never goes stale).
struct FileOutActivityCard: View {
    let activity: ToolActivity
    let onTryAgain: (() -> Void)?
    @Environment(\.sidePanel) private var panel

    private func openInPanel() {
        let versions = FileOutActivity.panelVersions(activity)
        guard let panel, let last = versions.last else { return }
        panel.open(title: FileOutActivity.filename(activity), versions: versions, selecting: last.n)
    }

    var body: some View {
        card.task(id: activity.state.rawValue) {
            if FileOutActivity.isFresh(activity), let panel, panel.autoOpenOnce(FileOutActivity.panelVersions(activity).last?.url) {
                openInPanel()
            }
        }
    }

    private var panelAction: (() -> Void)? {
        guard panel != nil, activity.state == .done else { return nil }
        return { openInPanel() }
    }

    @ViewBuilder private var card: some View {
        if let item = FileOutActivity.item(activity) {
            let chain = FileOutActivity.versions(activity)
            if chain.count > 1 {
                FileCardVersionSwitcher(latest: item, versions: chain)
                    .id("\(item.url.path)|versions")
                    .padding(.leading, Spacing.space5)
                    // Q-015 r5: a container, so the id names the card + switcher group instead of replacing the
                    // switcher's own (`fileVersionSwitcher` read `fileOutCard`, AX dump).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("fileOutCard")
            } else {
                CardHost(item: item, ready: activity.state == .done, onTryAgain: activity.state == .failed ? onTryAgain : nil,
                         onOpenInPanel: panelAction)
                    .id("\(item.url.path)|\(activity.state.rawValue)")
                    .padding(.leading, Spacing.space5)
                    .accessibilityIdentifier("fileOutCard")
            }
        }
    }

    private struct CardHost: View {
        @State private var model: FileCardViewModel
        let ready: Bool
        let onTryAgain: (() -> Void)?
        let onOpenInPanel: (() -> Void)?

        init(item: FileCardItem, ready: Bool, onTryAgain: (() -> Void)?, onOpenInPanel: (() -> Void)?) {
            _model = State(initialValue: FileCardViewModel(item: item))
            self.ready = ready
            self.onTryAgain = onTryAgain
            self.onOpenInPanel = onOpenInPanel
        }

        var body: some View {
            FileCard(model: model, showsThumbnail: ready, onOpenInPanel: onOpenInPanel, onTryAgain: onTryAgain)
        }
    }
}

/// M6.T12: the `create_chart` step: running → `act.creating` + a rendering ChartCard; done → the chart inline;
/// failed (spec error after the repair turn) → `chart.specError` with the data_ref's rows.
enum ChartActivity {
    static func isChart(_ a: ToolActivity) -> Bool {
        a.kind == .tool && (a.tool == CreateChartTool.name ||
            (a.tool == RunPythonTool.name && a.result.flatMap(FileOutResult.parse)?.format == "chart"))
    }

    static func args(_ a: ToolActivity) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any]) ?? [:]
    }

    static func title(_ a: ToolActivity) -> String {
        if a.tool == RunPythonTool.name, let result = a.result.flatMap(FileOutResult.parse) {
            return (result.file as NSString).deletingPathExtension
        }
        return (args(a)["title"] as? String) ?? "Chart"
    }

    static func label(_ a: ToolActivity) -> CopyText? {
        let name = FileOutNames.filename(title: title(a), ext: "png")
        switch a.state {
        case .running, .awaitingApproval: return CopyText(CopyKey("act.creating"), ["filename": name])
        case .done: return CopyText(CopyKey("act.created"), ["filename": name])
        default: return nil
        }
    }

    @MainActor
    static func model(_ a: ToolActivity) -> ChartCardModel? {
        switch a.state {
        case .running, .awaitingApproval:
            return ChartCardModel(title: title(a), pngURL: nil, state: .rendering)
        case .done:
            guard let r = a.result.flatMap(FileOutResult.parse) else { return nil }
            return ChartCardModel(title: title(a), pngURL: URL(fileURLWithPath: r.path), state: .ready)
        case .failed:
            let ref = (args(a)["data_ref"] as? String).flatMap { DataRefStore.shared.find(id: $0) }
            return ChartCardModel(title: title(a), pngURL: nil, state: .specError(a.result ?? ""), fallback: ref)
        default:
            return nil
        }
    }
}

struct ChartActivityCard: View {
    let activity: ToolActivity
    @Environment(\.sidePanel) private var panel

    var body: some View {
        if let model = ChartActivity.model(activity) {
            Host(model: model, onOpenInPanel: panel.flatMap { p in model.pngURL.map { url in { p.open(file: url, title: model.title) } } })
                .id("\(activity.id)|\(activity.state.rawValue)")
                .padding(.leading, Spacing.space5)
        }
    }

    private struct Host: View {
        @State var model: ChartCardModel
        let onOpenInPanel: (() -> Void)?
        var body: some View { ChartCardView(model: model, onOpenInPanel: onOpenInPanel) }
    }
}
