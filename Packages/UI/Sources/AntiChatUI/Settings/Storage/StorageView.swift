// M8.T10 step 3 (R-205; S-21 §10): Settings › Storage. A stacked bar of the eight categories with a text legend, total
// and free space + [Refresh]; per-model rows (size, last used, Reveal in Finder, Remove, Repair); the Models folder row
// ([Show in Finder], [Move…], Time Machine note); the documented data paths; Clean up…, Remove everything…, and
// Uninstall AntiChat… (M8.T11). Sizes come from StorageAccountant off the main thread, cached, refreshed on [Refresh],
// after a change, and when the page opens if older than 60 s. `ff.storageDashboard` off → the M2 Capabilities rows.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AppKit
import Charts
import SwiftUI

@MainActor @Observable
final class StorageModel {
    static let shared = StorageModel()

    var report: StorageReport?
    var measuring = false
    var cleanupItems: [CleanupItem] = []
    var moveProgress: Double?
    var moveFailed = false
    var showingCleanup = false
    var showingRemoveEverything = false
    var showingUninstall = false
    var freedNote: Int64?
    @ObservationIgnored var database: AppDatabase?

    /// Snapshot tests pin the paths: `DataPaths.current()` depends on this Mac (a Release container present hides the
    /// folders the Debug build shares with it, A-M8-T16a b).
    @ObservationIgnored var pathsOverride: DataPaths?
    var paths: DataPaths { pathsOverride ?? DataPaths.current() }

    /// VQ (S-21 Storage): the last report, kept in the container so the page opens with numbers (refreshed in the
    /// background) instead of "Calculating…" for the seconds a full scan takes.
    private var cacheURL: URL { paths.container.appendingPathComponent("storage-report.json") }
    @ObservationIgnored private var loadedCache = false

    func refreshIfStale(maxAge: TimeInterval = 60) {
        // The package test runner (snapshots) never measures this Mac's real folders: sizes would differ per run.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if report == nil, !loadedCache {
            loadedCache = true
            if let d = try? Data(contentsOf: cacheURL), let r = try? JSONDecoder().decode(StorageReport.self, from: d) { report = r }
        }
        if let r = report, Date().timeIntervalSince(r.measuredAt) < maxAge { return }
        refresh()
    }

    /// Settings opened (any section): start measuring now, so Storage has its numbers by the time it is shown.
    static func prewarm(database: AppDatabase?) {
        let m = shared
        if m.database == nil { m.database = database }
        m.refreshIfStale()
    }

    func refresh() {
        guard !measuring else { return }
        measuring = true
        let paths = self.paths, db = database, cache = cacheURL
        Task { @MainActor in
            // The packs' model ids (Settings › Capabilities' own facts): Storage counts the same files under each pack.
            let packs = PackManagementModel.shared
            if packs.selection == nil { await packs.refresh() }
            let hints = packs.storageHints()
            // VQ (S-21 Storage): a plain GCD queue, not the cooperative pool. The scan is blocking file I/O; on the
            // pool it queued behind the app's other utility work (and starved under load).
            DispatchQueue.global(qos: .userInitiated).async {
                let r = StorageAccountant.measure(paths, database: db, installs: hints)
                if let d = try? JSONEncoder().encode(r) { try? d.write(to: cache, options: .atomic) }
                Task { @MainActor in
                    self.report = r
                    self.measuring = false
                }
            }
        }
    }

    func prepareCleanup() {
        let paths = self.paths, db = database
        Task.detached(priority: .utility) {
            let loaded = !(await EngineClient.probeConnected()?.residentModels.isEmpty ?? true)
            // Release review: open downloads, verified files of models not installed yet and pending updates are not
            // orphans (the same retained set Remove models keeps).
            let active = await Self.retained()
            let items = CleanupPlanner.plan(paths, database: db, modelLoaded: loaded, active: active)
            await MainActor.run {
                self.cleanupItems = items
                self.showingCleanup = true
            }
        }
    }

    func cleanUp(_ checked: Set<CleanupItem.Kind>) {
        let items = cleanupItems, paths = self.paths, db = database
        Task.detached(priority: .utility) {
            // Re-marked at delete time: a download or install may have finished while the sheet was open.
            let freed = CleanupPlanner.execute(items, checked: checked, paths: paths, database: db, active: await Self.retained())
            await MainActor.run {
                self.freedNote = freed
                self.showingCleanup = false
                self.report = nil
                self.refresh()
            }
        }
    }

    nonisolated static func retained() async -> Set<String> {
        await ModelRemoval.retained(coordinator: DownloadsLaunch.coordinator, setup: SetupLaunch.installer,
                                    updates: ModelUpdatesLaunch.service, releasing: [])
    }

    func remove(_ row: StorageReport.ModelRow) {
        let models = ModelsDirectory(root: paths.models), db = database
        Task.detached(priority: .utility) {
            await PackManagementModel.removeModels([row.modelID], models: models, database: db) { _ = await EngineClient.evictConnected($0) }
            await MainActor.run { self.refresh() }
        }
    }

    func repair(_ row: StorageReport.ModelRow) {
        Task {
            _ = await ModelRepair.run(modelID: row.modelID)
            refresh()
        }
    }

    /// Move…: evict everything first (the helper maps the files), then copy + verify + bookmark + delete.
    func move(to parent: URL) {
        let paths = self.paths
        moveProgress = 0
        moveFailed = false
        Task.detached(priority: .utility) {
            _ = await EngineClient.evictConnected(Set(await EngineClient.probeConnected()?.residentModels ?? []))
            let mover = ModelsFolderMover(source: ModelsDirectory(root: paths.models), internalRoot: paths.modelsInternal)
            let ok = (try? mover.move(to: parent, location: ModelsFolderLocation()) { p in
                Task { @MainActor in self.moveProgress = p }
            }) != nil
            await MainActor.run {
                self.moveProgress = nil
                self.moveFailed = !ok
                self.refresh()
            }
        }
    }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
/// VisualQA probe (DEBUG): Settings › Storage has its numbers (not measuring, a report shown).
public enum StorageProbeStatus {
    @MainActor public static var settled: Bool { StorageModel.shared.report != nil && !StorageModel.shared.measuring }
}
#endif

/// Privacy & Data → Storage. On the page: the bar (what uses the disk) and Clean up. Advanced: the installed models,
/// the models folder, where the data lives, Remove everything, Uninstall.
struct StorageRows: View {
    let part: SettingsPart
    let database: AppDatabase?
    @State private var model = StorageModel.shared
    /// The installed models (often dozens of rows) stay closed until asked for.
    @State private var modelsOpen = false

    var body: some View {
        if FeatureFlag.storageDashboard.isEnabled() {
            if part == .main { main } else { advanced }
        }
    }

    @ViewBuilder private var main: some View {
        StorageBarView(report: model.report, measuring: model.measuring) { model.refresh() }
            .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset (text edges line up)
            .onAppear {
                model.database = database
                model.refreshIfStale(maxAge: 5)  // the page itself: fresh numbers (the cached or prewarmed ones show meanwhile)
            }
            .sheet(isPresented: $model.showingCleanup) {
                CleanUpSheet(items: model.cleanupItems, onClean: { model.cleanUp($0) }, onCancel: { model.showingCleanup = false })
            }
            .sheet(isPresented: $model.showingUninstall) {
                UninstallSheet(database: database) { model.showingUninstall = false }
            }
            .sheet(isPresented: $model.showingRemoveEverything) {
                RemoveEverythingSheet(database: database) { model.showingRemoveEverything = false }
            }
        SettingsItem("storage.cleanUp", description: CopyKey("storage.cleanUp.note")) {
            HStack {
                Button { model.prepareCleanup() } label: { Text(CopyKey("storage.cleanUp.cta")) }.probeID("settings.control.cleanUp")  // M9.T08: the verb, not the row label again
                if let f = model.freedNote {
                    Text(CopyText(CopyKey("storage.freed"), ["size": StorageBarView.size(f)])).typeStyle(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        if let models = model.report?.models, !models.isEmpty {
            SubDisclosure(title: "\(CopyKey("storage.loc.models").string()) (\(models.count))",
                          id: "storage.models", open: $modelsOpen) {
                ForEach(models) { r in
                    ModelRowView(row: r, onReveal: { NSWorkspace.shared.activateFileViewerSelecting([r.installView]) },
                                 onRemove: { model.remove(r) }, onRepair: { model.repair(r) })
                }
            }
        }
        ModelsFolderRow(path: model.paths.models, size: model.report?.locations[.models], progress: model.moveProgress,
                        failed: model.moveFailed) { url in model.move(to: url) }
        // VQ (S-21 Storage): friendly names and sizes; the paths themselves stay behind Show in Finder.
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("storage.paths")).typeStyle(.callout)
            ForEach(model.paths.locations, id: \.self) { loc in
                StorageLocationRow(location: loc, size: model.report.map { $0.locations[loc] ?? 0 }) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.revealTarget(loc)])
                }
            }
        }
        .padding(.vertical, Spacing.space2)
        .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset (text edges line up)
        .id("storage.paths")
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("settings.row.storage.paths")
        SettingsItem("storage.removeEverything", description: CopyKey("storage.removeEverything.note")) {
            Button(role: .destructive) { model.showingRemoveEverything = true } label: {
                Text(CopyKey("set.storage.removeEverything")).foregroundStyle(Color.danger)  // VQ: reads destructive
            }
            .probeID("settings.control.removeEverything")
        }
        SettingsItem("storage.uninstall", description: CopyKey("storage.uninstall.note")) {  // M8.T11 (R-226 AC1)
            Button(role: .destructive) { model.showingUninstall = true } label: {
                Text(CopyKey("set.storage.uninstall")).foregroundStyle(Color.danger)
            }
            .probeID("settings.control.uninstall")
        }
    }
}

/// The stacked bar (Swift Charts) + legend with sizes, total, free space, [Refresh].
struct StorageBarView: View {
    let report: StorageReport?
    let measuring: Bool
    let onRefresh: () -> Void

    static func size(_ b: Int64) -> String {
        // H7 size honesty: never "0.0 GB" for something that is there.
        if b <= 0 { return "0 KB" }
        if b < 1_000_000_000 { return ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return String(format: "%.1f GB", Double(b) / 1e9)
    }

    static func color(_ c: StorageCategory) -> Color {
        switch c {
        case .chatModels: .packChat
        case .voice: .packVoice
        case .photo: .packPhoto
        case .video: .packVideo
        case .evil: .evilBase
        case .chats: .info
        case .media: .success
        case .caches: .textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text(CopyKey("set.storage")).typeStyle(.headline)
                if let r = report {
                    Text(CopyText(CopyKey("storage.used"), ["size": Self.size(r.total)])).typeStyle(.body).foregroundStyle(Color.textSecondary)
                        .probeID("storage.total")
                } else if measuring {
                    Text(CopyKey("storage.measuring")).typeStyle(.body).foregroundStyle(Color.textSecondary)
                }
                Spacer()
                if measuring { ProgressView().controlSize(.small).accessibilityLabel(Text(CopyKey("storage.measuring"))) }
                Button(action: onRefresh) { Text(CopyKey("storage.refresh")) }.probeID("storage.refresh").disabled(measuring)
            }
            if let r = report {
                // VQ (S-21 Storage): the categories that take space, largest first (no column of "0 KB" rows).
                let shown = StorageCategory.allCases.filter { (r.bytes[$0] ?? 0) > 0 }
                    .sorted { (r.bytes[$0] ?? 0) > (r.bytes[$1] ?? 0) }
                Chart(shown, id: \.self) { c in
                    BarMark(x: .value("bytes", r.bytes[c] ?? 0), y: .value("", "all"))
                        .foregroundStyle(Self.color(c))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                // RC e8fe19986 audit (S-21 Storage, "Element has no description", the bar's 14 pt frame): a Chart keeps
                // an AX element of its own even under `.accessibilityHidden` (plain shapes did too, inside this
                // `.contain` card). It is one named element instead: the total it draws (the legend reads each part).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(CopyText(CopyKey("storage.used"), ["size": Self.size(r.total)])))
                .accessibilityAddTraits(.isImage)  // a role (AXImage): a named element of no role is "Unknown role"
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: Spacing.space2) {
                    ForEach(shown, id: \.self) { c in
                        HStack(spacing: Spacing.space2) {
                            Circle().fill(Self.color(c)).frame(width: 8, height: 8)
                            Text(CopyKey(c.copyKey)).typeStyle(.caption)
                            Text(verbatim: Self.size(r.bytes[c] ?? 0)).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .probeID("storage.legend.\(c.rawValue)")
                    }
                }
                if let free = r.freeBytes {
                    Text(CopyText(CopyKey("storage.free"), ["size": Self.size(free)])).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .padding(.vertical, Spacing.space2)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("storage.bar")
    }
}

struct ModelRowView: View {
    let row: StorageReport.ModelRow
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onRepair: () -> Void
    @State private var confirming = false

    /// "Chat · Normal" (+ " · Shared with another model") from the copy deck, never the slot's raw words. A helper
    /// model says what it does instead of the mode (r66 F1: the embedding model reads "Chat · Searches your files").
    static func modesLine(_ row: StorageReport.ModelRow) -> String {
        let pack = ModelPack(rawValue: row.pack).map(ModelOverrideRow.packName) ?? row.pack
        let what: String = switch row.role {
        case "embed", "rerank": CopyKey("storage.role.\(row.role)").string()
        case "chat_fast": CopyKey("set.cap.starter").string()
        default: CopyKey("set.cap.mode.\(row.mode == "evil" ? "evil" : "normal")").string()
        }
        return ([pack, what] + (row.shared ? [CopyKey("storage.model.shared").string()] : [])
            + (row.missing ? [CopyKey("storage.model.missing").string()] : [])).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ModelNames.name(row.modelID)).typeStyle(.body)
                Text(verbatim: Self.modesLine(row)).typeStyle(.caption)
                    .foregroundStyle(row.missing ? Color.warning : Color.textSecondary)
            }
            Spacer()
            Text(verbatim: StorageBarView.size(row.bytes)).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            Menu {
                Button(action: onReveal) { Text(CopyKey("storage.reveal")) }
                    .accessibilityIdentifier("storage.reveal")
                Button(action: onRepair) { Text(CopyKey("storage.repair")) }
                    .accessibilityIdentifier("storage.repair")
                Button(role: .destructive) { confirming = true } label: { Text(CopyKey("storage.remove")) }
                    .accessibilityIdentifier("storage.remove")
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(Text(CopyKey("chat.more")))  // M9.T01: "More"
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .confirmationDialog(Text(CopyKey("storage.remove")), isPresented: $confirming) {
                    Button(role: .destructive, action: onRemove) { Text(CopyKey("storage.remove")) }
                        .accessibilityIdentifier("storage.remove")
                }
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("storage.model.\(row.slot)")
    }
}

struct ModelsFolderRow: View {
    let path: URL
    let size: Int64?
    let progress: Double?
    let failed: Bool
    let onMove: (URL) -> Void

    /// "On Macintosh HD" — the disk the models are on, never the path (VQ S-21 Storage).
    private var volume: String {
        let name = (try? path.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? (try? path.deletingLastPathComponent().resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        return name.map { CopyText(CopyKey("storage.modelsFolder.on"), ["disk": $0]).string } ?? ""
    }

    var body: some View {
        SettingsItem("storage.modelsFolder", description: CopyKey("storage.modelsFolder.tm")) {
            VStack(alignment: .trailing, spacing: Spacing.space1) {
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([path]) } label: { Text(CopyKey("storage.showInFinder")) }
                        .probeID("storage.modelsFolder.show")
                    Button { choose() } label: { Text(CopyKey("storage.move")) }
                        .disabled(progress != nil).probeID("storage.modelsFolder.move")
                }
                .fixedSize()
                // Under the buttons, so neither the disk name nor a button label is cut short.
                Text(verbatim: [volume, size.map(StorageBarView.size) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                    .probeID("storage.modelsFolder.where")
                if let p = progress {
                    ProgressView(value: p).frame(width: 220)
                        .accessibilityLabel(Text(CopyKey("storage.modelsFolder")))  // own name (M9.T03)
                        .probeID("storage.move.progress")
                }
                if failed { Text(CopyKey("storage.move.failed")).typeStyle(.caption).foregroundStyle(Color.danger) }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onMove(url) }
    }
}

/// VQ (S-21 Storage): one place AntiChat keeps data — a friendly name, its size, [Show in Finder]. No path on screen.
struct StorageLocationRow: View {
    let location: StorageLocation
    /// nil while the first scan runs.
    let size: Int64?
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Text(CopyKey(location.copyKey)).typeStyle(.callout).foregroundStyle(Color.textPrimary)
            Spacer(minLength: Spacing.space2)
            if let size {
                Text(verbatim: StorageBarView.size(size)).typeStyle(.callout).foregroundStyle(Color.textSecondary).monospacedDigit()
            }
            Button(action: onReveal) { Text(CopyKey("storage.showInFinder")) }
                .buttonStyle(.link)
                .accessibilityIdentifier("storage.showInFinder.\(location.rawValue)")
        }
        .accessibilityElement(children: .contain)
        .probeID("storage.location.\(location.rawValue)")
    }
}
