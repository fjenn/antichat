import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
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

    /// The Run code row's description: an install error, "Getting ready · n%" while File tools arrives, or the note.
    var runCodeDescription: CopyText {
        if let errorKey { return CopyText(CopyKey(errorKey)) }
        if progress != nil { return CopyText(CopyKey("set.tools.codeInstalling"), ["percent": "\(Int(fraction * 100))"]) }
        return CopyText(CopyKey("set.tools.code.note"))
    }

    /// The install as something to await (the first `run_python` of a chat, FileToolsTools.ensureRuntime).
    func installAndWait() async -> Bool {
        refresh()
        if installed == nil, progress == nil { install() }
        while progress != nil { try? await Task.sleep(for: .milliseconds(200)) }
        return installed != nil && Defaults[.runCodeEnabled]
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

    /// On the page: Create files, Run code (+ install). Advanced: Allow network for code.
    let part: SettingsPart

    init(part: SettingsPart, database: AppDatabase?) {
        self.part = part
        _model = State(initialValue: FileToolsSettingsModel.shared(database: database))
    }

    var body: some View {
        Group {
            if part == .main { main } else {
                SettingsItem("codeNet", description: CopyKey("set.tools.codeNet.note")) {
                    Toggle(isOn: $network) { Text(CopyKey("set.tools.codeNet")) }
                        .toggleStyle(.accessibleSwitch).labelsHidden().disabled(model.installed == nil)
                        .probeID("settings.control.codeNet")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(ToolDefaults.runtimeDidChangeNotification))) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: CatalogStore.didChange)) { _ in model.refresh() }
    }

    @ViewBuilder private var main: some View {
        SettingsItem("createFiles", description: CopyKey("set.tools.createFiles.note")) {
            Toggle(isOn: $createFiles) { Text(CopyKey("set.tools.createFiles")) }
                .toggleStyle(.accessibleSwitch).labelsHidden().probeID("settings.control.createFiles")
        }
        // A plain switch: File tools installs by itself (FileToolsAutoInstall); turning the switch on before it
        // has arrived starts the install too, and the row says how far it is.
        SettingsItem("runCode", descriptionText: model.runCodeDescription) {
            Toggle(isOn: Binding(get: { model.installed != nil ? runCode : model.progress != nil },
                                 set: { on in if model.installed != nil { runCode = on } else if on { model.install() } })) {
                Text(CopyKey("set.tools.code"))
            }
            .toggleStyle(.accessibleSwitch).labelsHidden()
            .disabled(model.installed == nil && (model.runtime == nil || model.progress != nil))
            .probeID("settings.control.runCode")
        }
    }
}

/// File tools (the sandboxed Python runtime behind "Run code for analysis" and Office edits) installs by itself: once
/// onboarding is done and the Mac is online (never under Offline only), at launch, when the catalog arrives, and on
/// demand when a chat's first `run_python` runs before it is there. Nobody has to find a button in Settings.
@MainActor
enum FileToolsAutoInstall {
    private static var model: FileToolsSettingsModel?
    private static var observers: [NSObjectProtocol] = []
    private static var attempts = 0

    static func start(database: AppDatabase) {
        guard model == nil, !database.isInMemory, !UserDefaults.antichatIsIsolated else { return }
        let m = FileToolsSettingsModel.shared(database: database)
        model = m
        FileToolsTools.ensureRuntime.withLock { $0 = { await FileToolsAutoInstall.ensure() } }
        NotificationCenter.default.post(name: .init(ToolDefaults.runtimeDidChangeNotification), object: "filetools-runtime")
        for name in [CatalogStore.didChange, NetworkPolicyStore.didChange, PathStatus.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { kick() }
            })
        }
        kick()
    }

    static func ensure() async -> Bool { await model?.installAndWait() ?? false }

    /// Starts the install when it is missing and allowed (a few tries per launch; a failure shows on the Settings row).
    static func kick() {
        guard let m = model, attempts < 3, !OnboardingGate.shouldShow(), !NetworkPolicyStore.shared.offlineOnly else { return }
        m.refresh()
        guard m.installed == nil, m.progress == nil, m.runtime != nil, m.mayInstallNew() else { return }
        attempts += 1
        m.install()
    }
}
