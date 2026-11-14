// M8.T10 steps 6–7 (R-205 AC2/AC4, NFR-D7): the Clean up review sheet (nothing deleted before [Clean up], only the
// checked items) and the Remove everything sheet ([Export my data first], type REMOVE, then the removal and a
// relaunch into onboarding).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AppKit
import KeyboardShortcuts
import SwiftUI

struct CleanUpSheet: View {
    let items: [CleanupItem]
    let onClean: (Set<CleanupItem.Kind>) -> Void
    let onCancel: () -> Void
    @State private var checked: Set<CleanupItem.Kind>

    init(items: [CleanupItem], onClean: @escaping (Set<CleanupItem.Kind>) -> Void, onCancel: @escaping () -> Void) {
        self.items = items; self.onClean = onClean; self.onCancel = onCancel
        _checked = State(initialValue: Set(items.filter(\.defaultChecked).map(\.kind)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("storage.cleanUp.title")).typeStyle(.title3)
            if items.isEmpty {
                Text(CopyKey("storage.cleanUp.nothing")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            }
            ForEach(items) { i in
                Toggle(isOn: Binding(get: { checked.contains(i.kind) },
                                     set: { on in if on { checked.insert(i.kind) } else { checked.remove(i.kind) } })) {
                    HStack {
                        Text(CopyText(CopyKey(i.copyKey), ["count": "\(i.files.count)"])).typeStyle(.body)
                        Spacer()
                        Text(verbatim: StorageBarView.size(i.bytes)).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    }
                }
                .toggleStyle(.checkbox)
                .probeID("cleanup.item.\(i.kind.rawValue)")
            }
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("row.delete.cancel")) }.keyboardShortcut(.cancelAction)
                Button { onClean(checked) } label: { Text(CopyKey("storage.cleanUp.cta")) }
                    .keyboardShortcut(.defaultAction).disabled(checked.isEmpty).probeID("cleanup.confirm")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 460)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("cleanupSheet")
    }
}

/// The confirmed removal; `RemoveEverythingSheet` and the DEBUG `-RunRemoveEverything YES` hook both call it.
enum RemoveEverythingRunner {
    static func hooks() -> RemovalHooks {
        var h = RemovalHooks()
        h.cancelJobs = {
            // Review fix (M8.T16): downloads, picture/video jobs and the linked-folder watchers stop before the
            // container goes, so nothing writes into it afterwards.
            await DownloadsLaunch.coordinator?.cancelAll()
            try? await MediaJobQueue.shared?.cancelForQuit()
            await MainActor.run { ProjectFolderWatchers.shared.stopAll() }
        }
        h.stopEngine = {
            // Evict every model (waits for running leases), then end the sessions; the helper exits on its own.
            let resident = Set(await EngineClient.probeConnected()?.residentModels ?? [])
            _ = await EngineClient.evictConnected(resident)
            EngineClient.disconnectAll()
        }
        h.relayForget = { "not configured" }  // no Composio relay client in this build (M7 relay forget lands with it)
        h.unregisterLoginItem = { LoginItem.apply(false) }
        // Every name, the global quick panel included (M8.T13), and M11's reserved dictation name.
        h.resetShortcuts = { ShortcutStore.reset(ShortcutCatalog.names + [KeyboardShortcuts.Name("dictation")]) }
        return h
    }

    /// A DEBUG `ANTICHAT_ROOT` run (tools/install-test dev-run.sh) touches only its scratch tree: a scratch defaults
    /// domain, no login item / shortcut changes, and Keychain items of `ANTICHAT_KEYCHAIN_PREFIX` only.
    static func scratchSafe(_ paths: DataPaths, _ h: inout RemovalHooks) -> (keychain: String, defaults: String?) {
        // A Debug build beside the Release app's data: no `app.antichat.*` Keychain item is touched (review fix).
        if paths.keepsReleaseShared { return ("app.antichat.debug-keeps-release.", nil) }
        guard paths.isScratch else { return (DataPaths.keychainPrefix, nil) }
        h.unregisterLoginItem = {}
        h.resetShortcuts = {}
        h.clearNotifications = {}
        let prefix = ProcessInfo.processInfo.environment["ANTICHAT_KEYCHAIN_PREFIX"] ?? "app.antichat.scratch-none."
        return (prefix, "app.antichat.scratch-\(getpid())")
    }

    static func run() async -> RemovalResult {
        let paths = DataPaths.current()
        var h = hooks()
        let safe = scratchSafe(paths, &h)
        var svc = RemoveEverythingService(paths: paths, hooks: h)
        svc.keychainPrefix = safe.keychain
        svc.defaultsDomain = safe.defaults
        let r = await svc.run()
        AppLog.log(.store, .info, "remove everything: removed \(r.removed.count), leftovers \(r.leftovers.count), keychain \(r.keychainLeft.count), relay \(r.relayNote)")
        return r
    }
}

struct RemoveEverythingSheet: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var typed = ""
    @State private var running = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("set.storage.removeEverything")).typeStyle(.title3)
            Text(CopyKey("set.storage.removeEverything.confirm")).typeStyle(.body).fixedSize(horizontal: false, vertical: true)
            if FeatureFlag.exportAll.isEnabled() {
                Button { exporting = true } label: { Text(CopyKey("storage.exportFirst")) }.probeID("removeEverything.export")
            }
            TextField(text: $typed) { Text(CopyKey("storage.removeEverything.type")) }
                .textFieldStyle(.roundedBorder).probeID("removeEverything.field")
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(action: onClose) { Text(CopyKey("row.delete.cancel")) }.keyboardShortcut(.cancelAction).disabled(running)
                Button(role: .destructive) {
                    running = true
                    Task {
                        _ = await RemoveEverythingRunner.run()
                        AppRelaunch.relaunch(sweepData: true)  // onboarding again (Defaults and the container are gone)
                    }
                } label: { Text(CopyKey("set.storage.removeEverything")) }
                    .disabled(typed != "REMOVE" || running)
                    .probeID("removeEverything.confirm")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 480)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("removeEverythingSheet")
        .sheet(isPresented: $exporting) { ExportAllView(database: database) { exporting = false } }
    }
}
