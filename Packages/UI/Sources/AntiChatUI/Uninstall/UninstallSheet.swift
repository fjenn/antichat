// M8.T11 step 1 (R-226 AC1; S-24): AntiChat › Uninstall AntiChat… and Settings › Storage › Uninstall AntiChat… open
// this sheet: what goes, with sizes and paths (StorageAccountant + DataPaths, a moved Models folder included), the
// login item and global shortcuts; [Export my data first]; "Type UNINSTALL to confirm"; [Uninstall] (destructive,
// enabled only on the exact word). On confirm: UninstallService (in-process removals + the detached waiter), the app
// bundle to the Trash, quit. `-UninstallDryRun YES` (DEBUG, UninstallUITests) stops before the destructive step.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI

/// The configured service (scratch-safe in a DEBUG `ANTICHAT_ROOT` run, like Remove everything).
@MainActor func uninstallService() -> UninstallService {
    let paths = DataPaths.current()
    var hooks = RemoveEverythingRunner.hooks()
    hooks.clearNotifications = { NotificationCleanup.removeAllDelivered() }
    let safe = RemoveEverythingRunner.scratchSafe(paths, &hooks)
    var svc = UninstallService(paths: paths, hooks: hooks)
    svc.keychainPrefix = safe.keychain
    svc.defaultsDomain = safe.defaults
    return svc
}

enum UninstallRunner {
    enum Outcome: Equatable { case dryRun, failed, started }

    /// Removals → waiter → Trash → quit. Nothing destructive in a dry run. Review fix (M8.T16): when the removal
    /// waiter cannot be written or started, the app stays where it is and says so (it is the one thing that can still
    /// remove the data) instead of moving itself to the Trash.
    @MainActor static func run(dryRun: Bool = AppDefaults.standard.bool(forKey: "UninstallDryRun")) async -> Outcome {
        guard !dryRun else { return .dryRun }
        do {
            _ = try await uninstallService().run()
        } catch {
            AppLog.log(.store, .error, "uninstall: waiter: \(error)")
            return .failed
        }
        // Read-only volume (launched from the DMG): the data still goes; the sheet already said to drag the app.
        // Isolation audit: nonisolated completion (a closure written here is main-actor isolated, and NSWorkspace
        // calls it on the queue it was called from, which is not guaranteed to be the main queue).
        let done: @Sendable ([URL: URL], (any Error)?) -> Void = WorkspaceCompletion.onMain { err in
            if let err { AppLog.log(.store, .error, "uninstall: recycle: \(err)") }
            NSApp.terminate(nil)
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL], completionHandler: done)
        return .started
    }
}

struct UninstallSheet: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var typed = ""
    @State private var report: StorageReport?
    @State private var exporting = false
    @State private var running = false
    @State private var failed = false
    private let paths = DataPaths.current()

    private var bundleOnReadOnlyVolume: Bool {
        (try? Bundle.main.bundleURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("uninstall.title")).typeStyle(.title3)
            VStack(alignment: .leading, spacing: Spacing.space2) {
                row(CopyKey("uninstall.item.models"), bytes: modelBytes, path: paths.models.path)
                row(CopyKey("uninstall.item.chats"), bytes: (report?.bytes[.chats] ?? 0) + (report?.bytes[.media] ?? 0), path: paths.container.path)
                row(CopyKey("uninstall.item.settings"), bytes: nil, path: paths.entries.first { $0.kind == .preferences }?.url.path ?? "")
                row(CopyKey("uninstall.item.caches"), bytes: report?.bytes[.caches], path: paths.caches.path)
                row(CopyKey("uninstall.item.logs"), bytes: nil, path: paths.logs.path)
                Text(CopyKey("uninstall.item.loginShortcuts")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            }
            .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
            .probeID("uninstall.list")
            if bundleOnReadOnlyVolume {
                Text(CopyKey("uninstall.dragYourself")).typeStyle(.caption).foregroundStyle(Color.warning)
            }
            if FeatureFlag.exportAll.isEnabled() {
                Button { exporting = true } label: { Text(CopyKey("storage.exportFirst")) }.probeID("uninstall.export")
            }
            if failed {
                Text(CopyKey("uninstall.failed")).typeStyle(.callout).foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true).probeID("uninstall.failed")
            }
            TextField(text: $typed) { Text(CopyKey("uninstall.type")) }
                .textFieldStyle(.roundedBorder).probeID("uninstall.field")
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(action: onClose) { Text(CopyKey("row.delete.cancel")) }.keyboardShortcut(.cancelAction).disabled(running)
                Button(role: .destructive) {
                    running = true
                    Task { @MainActor in
                        switch await UninstallRunner.run() {
                        case .started: break
                        case .dryRun: running = false; onClose()
                        case .failed: running = false; failed = true
                        }
                    }
                } label: { Text(CopyKey("uninstall.cta")) }
                    .disabled(typed != "UNINSTALL" || running)
                    .probeID("uninstall.confirm")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 520)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("uninstallSheet")
        .task {
            let p = paths, db = database
            report = await Task.detached(priority: .utility) { StorageAccountant.measure(p, database: db) }.value
        }
        .sheet(isPresented: $exporting) { ExportAllView(database: database) { exporting = false } }
    }

    private var modelBytes: Int64? {
        report.map { r in [StorageCategory.chatModels, .voice, .photo, .video, .evil].reduce(0) { $0 + (r.bytes[$1] ?? 0) } }
    }

    private func row(_ title: CopyKey, bytes: Int64?, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(title).typeStyle(.body)
            if let b = bytes { Text(verbatim: StorageBarView.size(b)).typeStyle(.callout).foregroundStyle(Color.textSecondary) }
            Spacer(minLength: Spacing.space2)
            Text(verbatim: path).typeStyle(.caption).foregroundStyle(Color.textTertiary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Help › How to Uninstall: the bundled `uninstall.md` (offline; the website page's source in M10).
struct UninstallHelpSheet: View {
    let onClose: () -> Void

    static func text() -> AttributedString {
        guard let url = BundledDocument.localizedURL("uninstall", subdirectory: nil),  // M9.T04: UI language
              let s = try? String(contentsOf: url, encoding: .utf8) else { return AttributedString("") }
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ScrollView {
                Text(Self.text()).typeStyle(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space3)
            }
            .frame(height: 420)
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("systemReport.close")) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 600)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("uninstallHelp")
    }
}
