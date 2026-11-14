// M8.T06 steps 2, 8, 9 (R-092; S-24 "Import guide"): one sheet in three states. Guide (ported in design from
// osaurus@2922745 ImportGuideSheet, re-skinned on AntiChatDesign: per-provider steps + links that open the
// providers' export pages in the browser) with [Choose File…] (.zip / .json) → progress (real % of the
// conversations file read, chats done) with [Cancel] → summary (counts, kept-as-text types, Cancelled) or the
// error line (`import.unsupported` / `import.failed`).
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class ImportFlowModel {
    enum Phase: Equatable { case guide, running(ImportProgress), done(ImportSummary), failed(String) }
    var phase: Phase = .guide
    /// AT-092: the deferred full-text pass after the import (nil = none ran; it goes on after the sheet closes).
    var searchProgress: Double?
    /// M8.T07 step 3: an AntiChat export's settings are restored only after the user confirms.
    var settingsRestored = false
    private var coordinator: ImportCoordinator?

    func choose(database: AppDatabase) {
        #if DEBUG
        // UI tests: `-ImportFile <path>` stands in for the open panel (XCUITest cannot drive NSOpenPanel reliably).
        if let i = CommandLine.arguments.firstIndex(of: "-ImportFile"), i + 1 < CommandLine.arguments.count {
            start(URL(fileURLWithPath: CommandLine.arguments[i + 1]), database: database)
            return
        }
        #endif
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url, database: database)
    }

    func start(_ url: URL, database: AppDatabase) {
        let c = ImportCoordinator(database: database)
        coordinator = c
        phase = .running(ImportProgress(bytesDone: 0, bytesTotal: 1, chatsDone: 0))
        Task { [weak self] in
            for await e in c.start(url) {
                guard let self else { return }
                switch e {
                case .progress(let p): self.phase = .running(p)
                case .finished(let s):
                    self.phase = .done(s)
                    // Review fix (M8.T16): imported project files carry no index; build it (linked: next rescan).
                    if s.projects > 0 { ProjectFolderWatchers.shared.reindexPending(database: database) }
                case .failed(let key): self.phase = .failed(key)
                case .searchIndex(let f): self.searchProgress = f
                }
            }
        }
    }

    func cancel() { coordinator?.cancel() }

    func restoreSettings(_ json: Data, into defaults: UserDefaults = .antichat) {
        ExportSettings.restore(json, into: defaults)
        settingsRestored = true
    }

    /// The summary lines (step 9).
    static func lines(_ s: ImportSummary) -> [String] {
        var out = [CopyText(CopyKey("import.summary"), ["chats": "\(s.chats)", "messages": "\(s.messages)", "images": "\(s.images)",
                                                        "skipped": "\(s.skipped)"]).string]
        if s.replaced > 0 { out.append(CopyText(CopyKey("import.summary.updated"), ["count": "\(s.replaced)"]).string) }
        for (type, n) in s.kept.sorted(by: { $0.key < $1.key }) {
            out.append(CopyText(CopyKey("import.summary.kept"), ["count": "\(n)", "type": type]).string)
        }
        if s.missingMedia > 0 { out.append(CopyText(CopyKey("import.summary.missingMedia"), ["count": "\(s.missingMedia)"]).string) }
        if s.cancelled { out.append(CopyKey("import.summary.cancelled").string()) }
        return out
    }
}

struct ImportSheet: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var model = ImportFlowModel()

    static let chatGPTExport = URL(string: "https://chatgpt.com/#settings/DataControls")!
    static let claudeExport = URL(string: "https://claude.ai/settings/data-privacy-controls")!

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("import.guide.title")).typeStyle(.title3)
            switch model.phase {
            case .guide: guide
            case .running(let p): running(p)
            case .done(let s): summary(s)
            case .failed(let key):
                Text(CopyKey(key)).typeStyle(.body).foregroundStyle(Color.danger).probeID("import.error")
                HStack { Spacer(); Button(action: onClose) { Text(CopyKey("import.done")) }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 480)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("importSheet")
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("import.guide.body")).typeStyle(.body).foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            provider("bubble.left.and.bubble.right", CopyKey("import.guide.chatgpt"), CopyKey("import.guide.openChatGPT"), Self.chatGPTExport)
            provider("sparkle", CopyKey("import.guide.claude"), CopyKey("import.guide.openClaude"), Self.claudeExport)
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("import.cancel")) }.keyboardShortcut(.cancelAction)
                Button { if let database { model.choose(database: database) } } label: { Text(CopyKey("import.choose")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(database == nil)
                    .probeID("import.choose")
            }
        }
    }

    private func provider(_ symbol: String, _ steps: CopyKey, _ link: CopyKey, _ url: URL) -> some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            Image(systemName: symbol).foregroundStyle(Color.textSecondary).frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(steps).typeStyle(.subhead).fixedSize(horizontal: false, vertical: true)
                Button { NSWorkspace.shared.open(url) } label: { Text(link).typeStyle(.footnote) }.buttonStyle(.link)
            }
        }
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceHover))
    }

    private func running(_ p: ImportProgress) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ProgressView(value: p.fraction).probeID("import.progress")
            Text(CopyText(CopyKey("import.progress"), ["chats": "\(p.chatsDone)", "percent": "\(Int(p.fraction * 100))"]))
                .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
            HStack { Spacer(); Button { model.cancel() } label: { Text(CopyKey("import.cancel")) }.probeID("import.cancel") }
        }
    }

    private func summary(_ s: ImportSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(ImportFlowModel.lines(s), id: \.self) { Text(verbatim: $0).typeStyle(.body).fixedSize(horizontal: false, vertical: true) }
            if let f = model.searchProgress {
                // AT-092: the chats are usable now; search catches up in the background.
                if f < 1 {
                    ProgressView(value: f).probeID("import.searchProgress")
                    Text(CopyText(CopyKey("import.search.progress"), ["percent": "\(Int(f * 100))"]))
                        .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                } else {
                    Text(CopyKey("import.search.ready")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .probeID("import.searchReady")
                }
            }
            if let json = s.settingsJSON {  // M8.T07 step 3: ask first (Evil and consent are never restored silently)
                if model.settingsRestored {
                    Text(CopyKey("import.settings.restored")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                } else {
                    HStack {
                        Text(CopyKey("import.settings.ask")).typeStyle(.body)
                        Spacer()
                        Button { model.restoreSettings(json) } label: { Text(CopyKey("import.settings.restore")) }
                            .probeID("import.restoreSettings")
                    }
                }
            }
            HStack { Spacer(); Button(action: onClose) { Text(CopyKey("import.done")) }.keyboardShortcut(.defaultAction).probeID("import.done") }
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("import.summary")
    }
}

/// File › Import Chats… → the Privacy section opens the sheet when it appears.
final class ImportRequest: @unchecked Sendable {
    static let shared = ImportRequest()
    private let lock = NSLock()
    private var pending = false
    func request() { lock.lock(); pending = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { pending = false; lock.unlock() }; return pending }
}
