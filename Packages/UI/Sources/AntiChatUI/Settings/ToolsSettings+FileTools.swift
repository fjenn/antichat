import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Defaults
import Observation
import SwiftUI

@MainActor @Observable
final class FileToolsSettingsModel {
    var installed: InstalledRuntime?
    var runtime: CatalogRuntime?
    var progress: Int64?
    var errorKey: String?
    private let database: AppDatabase?
    private let catalogStore: CatalogStore?
    /// RC review P2-9: a runtime install, like a model install (`InstallQueue`), starts only from a verified,
    /// unexpired catalog and never after a bad signature (`CatalogStore.mayInstallNew`). No store: no install.
    @ObservationIgnored var mayInstallNew: () -> Bool = { false }

    /// One model per database, shared by the Settings row and the Office edit offer card (one install at a time).
    private static var byDatabase: [ObjectIdentifier: FileToolsSettingsModel] = [:]
    static func shared(database: AppDatabase?) -> FileToolsSettingsModel {
        guard let database else { return FileToolsSettingsModel(database: nil) }
        if let m = byDatabase[ObjectIdentifier(database)] { return m }
        let m = FileToolsSettingsModel(database: database)
        byDatabase[ObjectIdentifier(database)] = m
        return m
    }

    init(database: AppDatabase?, catalogStore: CatalogStore? = CatalogLaunch.shared) {
        self.database = database
        self.catalogStore = catalogStore
        mayInstallNew = { catalogStore?.mayInstallNew == true }
        refresh()
    }

    func refresh() {
        installed = database.map { RuntimeInstaller(registry: RuntimeRegistry(database: $0)).installed("filetools-runtime") } ?? nil
        runtime = catalogStore?.catalog?.runtime("filetools-runtime") ?? catalogStore?.snapshot.verifiedData.flatMap {
            try? ModelCatalog.decode($0).runtime("filetools-runtime")
        }
    }

    /// Install progress 0…1 (bytes received over the catalog's download size).
    var fraction: Double {
        guard let progress, let total = runtime?.sizeBytes, total > 0 else { return 0 }
        return min(1, max(0, Double(progress) / Double(total)))
    }

    var sizeLabel: String {
        runtime.map { ByteCountFormatter.string(fromByteCount: $0.sizeBytes, countStyle: .file) } ?? "85 MB"
    }

    var installLabel: String { CopyKey("sandbox.notInstalled").string(["size": sizeLabel]) }

    /// The Run code row's description: the reason (no File tools yet, with their size), an install error, or the note.
    var runCodeDescription: CopyText {
        if let errorKey { return CopyText(CopyKey(errorKey)) }
        if installed == nil, progress == nil { return CopyText(CopyKey("set.tools.code.needsRuntime"), ["size": sizeLabel]) }
        return CopyText(CopyKey("set.tools.code.note"))
    }

    func install() {
        guard let database, let runtime, progress == nil else { return }
        guard mayInstallNew() else { errorKey = "catalog.badSignature"; return }  // fail closed, as models do
        errorKey = nil
        progress = 0
        let installer = RuntimeInstaller(registry: RuntimeRegistry(database: database))
        Task {
            do {
                _ = try await installer.install(runtime) { bytes in
                    Task { @MainActor in self.progress = bytes }
                }
                Defaults[.runCodeEnabled] = DeviceTier.current() != .t0
                NotificationCenter.default.post(name: .init(ToolDefaults.runtimeDidChangeNotification), object: "filetools-runtime")
            } catch let error as RuntimeInstallError {
                errorKey = error.copyKey
            } catch {
                errorKey = "download.failed"
            }
            refresh()
            progress = nil
        }
    }
}

struct FileToolsSettingsRows: View {
    @State private var model: FileToolsSettingsModel
    @Default(.createFilesEnabled) private var createFiles
    @Default(.runCodeEnabled) private var runCode
    @Default(.allowNetworkForCode) private var network

    init(database: AppDatabase?) { _model = State(initialValue: FileToolsSettingsModel.shared(database: database)) }

    var body: some View {
        SettingsItem("createFiles", description: CopyKey("set.tools.createFiles.note")) {
            Toggle(isOn: $createFiles) { Text(CopyKey("set.tools.createFiles")) }
                .toggleStyle(.accessibleSwitch).labelsHidden().probeID("settings.control.createFiles")
        }
        SettingsItem("runCode", descriptionText: model.runCodeDescription) {
            if model.installed != nil {
                Toggle(isOn: $runCode) { Text(CopyKey("set.tools.code")) }
                    .toggleStyle(.accessibleSwitch).labelsHidden().probeID("settings.control.runCode")
            } else {
                if model.progress != nil {
                    HStack {
                        ProgressView(value: model.fraction).frame(width: 120)
                            .accessibilityLabel(Text(CopyKey("set.tools.code")))  // own name (M9.T03)
                        Text(CopyKey("set.tools.codeInstalling").string(["percent": "\(Int(model.fraction * 100))"]))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                    .probeID("settings.control.runCode")
                } else {
                    // VQ (S-21 Tools, M10): a short verb; the why and the size are in the row's description.
                    Button { model.install() } label: { Text(CopyKey("set.tools.code.get")) }
                        .disabled(model.runtime == nil)
                        .probeID("settings.control.runCode")
                }
            }
        }
        SettingsItem("codeNet") {
            Toggle(isOn: $network) { Text(CopyKey("set.tools.codeNet")) }
                .toggleStyle(.accessibleSwitch).labelsHidden().disabled(model.installed == nil)
                .probeID("settings.control.codeNet")
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(ToolDefaults.runtimeDidChangeNotification))) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: CatalogStore.didChange)) { _ in model.refresh() }
    }
}
