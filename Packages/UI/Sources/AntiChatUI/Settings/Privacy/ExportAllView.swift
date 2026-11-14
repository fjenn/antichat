// M8.T07 step 2 (R-093 AC1; S-21 Privacy & Data, S-24): Export all data… → options (Include pictures, videos and
// files ({size}), default on) → NSSavePanel (the user picks the location) → progress with a real % (bytes written of
// the estimate) and [Cancel] (the partial zip is deleted) → "Exported to {filename}." [Show in Finder]. The zip is
// written by ExportAllWriter (AntiChatStorage) on a utility thread. Settings: the app's own defaults domain, filtered
// by ExportSettings (no secrets, bookmarks, consent or window state; Keychain items are never read).
import AntiChatDesign
import AntiChatStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class ExportFlowModel {
    enum Phase: Equatable { case options, running(ExportProgress), done(URL), failed }
    var phase: Phase = .options
    var includeMedia = true
    var mediaBytes: Int64?
    private let cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func reset() { lock.lock(); value = false; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func load(_ database: AppDatabase) {
        guard mediaBytes == nil else { return }
        Task.detached { [weak self] in
            let bytes = (try? ExportAllWriter(database: database).estimate())?.mediaBytes ?? 0
            await MainActor.run { self?.mediaBytes = bytes }
        }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: mediaBytes ?? 0, countStyle: .file) }

    /// The app's own preferences (the Settings store: the bundle's domain, or the DEBUG `-DefaultsSuite`), filtered.
    static func settingsJSON() -> Data {
        let domain = UserDefaults.antichatIsIsolated ? UserDefaults.antichat.dictionaryRepresentation()
            : Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        return ExportSettings.json(domain)
    }

    func choose(database: AppDatabase) {
        var url: URL?
        #if DEBUG
        // UI tests: `-ExportFile <path>` stands in for the save panel (XCUITest cannot drive NSSavePanel reliably).
        if let i = CommandLine.arguments.firstIndex(of: "-ExportFile"), i + 1 < CommandLine.arguments.count {
            url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        #endif
        if url == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = AntiChatExportFormat.fileName()
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        start(url, database: database)
    }

    func start(_ url: URL, database: AppDatabase) {
        cancelFlag.reset()
        phase = .running(ExportProgress(bytesDone: 0, bytesTotal: 1))
        let options = ExportOptions(includeMedia: includeMedia, settingsJSON: Self.settingsJSON(),
                                    appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
        let flag = cancelFlag
        let (stream, sink) = AsyncStream<Phase>.makeStream(bufferingPolicy: .bufferingNewest(8))
        Thread.detachNewThread {
            Thread.current.qualityOfService = .utility
            do {
                let r = try ExportAllWriter(database: database).write(to: url, options: options,
                                                                       progress: { sink.yield(.running($0)) },
                                                                       isCancelled: { flag.isSet })
                if !r.cancelled { FileProtection.protectFile(url) }  // M8.T08 (NFR-PR4): the archive holds every chat
                sink.yield(r.cancelled ? .options : .done(url))
            } catch {
                sink.yield(.failed)
            }
            sink.finish()
        }
        Task { [weak self] in
            for await p in stream { self?.phase = p }
        }
    }

    func cancel() { cancelFlag.set() }
}

struct ExportAllView: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var model = ExportFlowModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("export.title")).typeStyle(.title3)
            switch model.phase {
            case .options: options
            case .running(let p): running(p)
            case .done(let url): done(url)
            case .failed:
                Text(CopyKey("export.failed")).typeStyle(.body).foregroundStyle(Color.danger).probeID("export.error")
                HStack { Spacer(); Button(action: onClose) { Text(CopyKey("export.close")) }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 460)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("exportSheet")
        .onAppear { if let database { model.load(database) } }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("export.body")).typeStyle(.body).foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $model.includeMedia) {
                Text(CopyText(CopyKey("export.includeMedia"), ["size": model.sizeText]))
            }
            .toggleStyle(.checkbox)
            .probeID("export.includeMedia")
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("export.cancel")) }.keyboardShortcut(.cancelAction)
                Button { if let database { model.choose(database: database) } } label: { Text(CopyKey("export.choose")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(database == nil)
                    .probeID("export.choose")
            }
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("export.options")
    }

    private func running(_ p: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ProgressView(value: p.fraction).probeID("export.progress")
            Text(CopyText(CopyKey("export.progress"), ["percent": "\(Int(p.fraction * 100))"]))
                .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
            HStack { Spacer(); Button { model.cancel() } label: { Text(CopyKey("export.cancel")) }.probeID("export.cancel") }
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyText(CopyKey("export.done"), ["filename": url.lastPathComponent])).typeStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .probeID("export.done")
            HStack {
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Text(CopyKey("export.showInFinder")) }
                    .probeID("export.showInFinder")
                Button(action: onClose) { Text(CopyKey("export.close")) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// File › Export All Data… → the Privacy section opens the sheet when it appears.
final class ExportRequest: @unchecked Sendable {
    static let shared = ExportRequest()
    private let lock = NSLock()
    private var pending = false
    func request() { lock.lock(); pending = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { pending = false; lock.unlock() }; return pending }
}
