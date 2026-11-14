// M4 lead decision (the ≈ 170 s first ChildSafetyCheck compile): once the Photo or Video pack's detector files are
// installed (download verified, install views made), the helper compiles them into its cache in the background
// (`EngineClient.prepareSafety`), and the pack's install row stays "Checking" until that ends, so the first image
// never pays the compile. The helper keys the compiled form by the detectors' sha256: an unchanged set answers at
// once, a model change recompiles. Nothing is evaluated here; MediaOutputGate stays the only ChildSafetyCheck user.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatPlatform
import Foundation

@MainActor
public final class SafetyPreparation {
    public static let shared = SafetyPreparation()

    /// The manifest being compiled now (nil = idle).
    public private(set) var running: SafetyManifest?
    /// Manifests the helper reported compiled in this process.
    private var done: Set<SafetyManifest> = []
    /// Runs one preparation; replaced by tests.
    var prepare: @Sendable (SafetyManifest) async -> Bool = { m in
        let client = EngineClient(appBuild: "safety-prepare")
        defer { client.disconnect() }
        do { try await client.prepareSafety(m); return true } catch { return false }
    }
    /// Called when a preparation ends (progress refresh).
    var onChange: @MainActor () -> Void = {
        Task { await SetupLaunch.refresh(); await PackManagementModel.shared.refresh() }
    }

    init() {}

    /// Install groups whose row waits for the compile.
    public var preparingGroups: Set<String> { running == nil ? [] : [ModelPack.photo.rawValue, ModelPack.video.rawValue] }

    /// Starts the compile for `manifest` when its detectors are installed and it was not compiled yet in this process.
    /// `installed`: model ids with an install view; `detectorIDs`: the `csam_check` slot's models.
    public func ensure(_ manifest: SafetyManifest?, detectorIDs: [String], installed: Set<String>) {
        guard let m = manifest, !detectorIDs.isEmpty, detectorIDs.allSatisfy(installed.contains),
              running == nil, !done.contains(m) else { return }
        running = m
        let prepare = prepare
        Task { @MainActor in
            let ok = await prepare(m)
            if ok { done.insert(m) }
            running = nil
            onChange()
        }
    }

    /// The setup install's hook (SetupLaunch.refresh): the Settings model holds the selection + catalog.
    func ensureFromPacks(installed: Set<String>) {
        let pm = PackManagementModel.shared
        guard let s = pm.selection, let c = pm.catalog else { Task { await pm.refresh() }; return }
        let d = Self.detectors(selection: s, catalog: c, installs: DownloadsLaunch.models.installs)
        ensure(d.manifest, detectorIDs: d.ids, installed: installed)
    }

    /// The `csam_check` slot's model ids and detector manifest of `selection` (nil manifest = no slot).
    static func detectors(selection: Selection, catalog: ModelCatalog, installs: URL) -> (ids: [String], manifest: SafetyManifest?) {
        let ids = selection.slots.first { $0.role == "csam_check" }?.installIDs ?? []
        return (ids, InstalledPhotoModels.safety(selection: selection, catalog: catalog, installs: installs))
    }
}
