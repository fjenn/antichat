// M4.T06: the composition root's `PhotoModelProviding` — the Photo pack's selected models (Settings › Capabilities'
// selection over the signed catalog) resolved to their install views `<Models>/installs/<id>/<file>`. The create model
// is the slot's `image` entry with its `requires` (text encoder `--llm`, VAE `--vae`); the edit model the `image_edit`
// entry (+ `--llm_vision` mmproj). The ChildSafetyCheck files come from the `csam_check` slot with the catalog's pinned
// sha256, so the helper's gate re-verifies them before loading (damaged ⇒ fail closed with the repair size).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatTools
import Foundation

public struct InstalledPhotoModels: PhotoModelProviding {
    public init() {}

    struct Facts: Sendable {
        var selection: Selection
        var catalog: ModelCatalog
        var installs: URL
    }

    func facts() async -> Facts? {
        let model = await MainActor.run { PackManagementModel.shared }
        if await MainActor.run(body: { model.selection == nil }) { await model.refresh() }
        return await MainActor.run {
            guard let s = model.selection, let c = model.catalog else { return nil }
            return Facts(selection: s, catalog: c, installs: DownloadsLaunch.models.installs)
        }
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// `-UseScriptedImageEngine <script.json>` (UI tests, the visual-QA probe): every photo tool runs the helper's
    /// ScriptedImageEngine (gradients, no weights); the detectors are the dev cache's real ones
    /// (SafetyManifestResolver.devModelsRoot), so the gate runs for real. nil = not scripted.
    static let scripted: ScriptedImageScript? = LaunchOptions.current.scriptedImageScript
        .flatMap { try? ScriptedImageScript.load(URL(fileURLWithPath: $0)) }
    #endif

    public func modelSet(for tool: String) async -> ImageModelSet? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let s = Self.scripted { return tool == "edit_image.best" ? nil : s.modelSet() }
        #endif
        guard let f = await facts() else { return nil }
        return Self.modelSet(tool: tool, selection: f.selection, catalog: f.catalog, installs: f.installs)
    }

    public func speedClass() async -> ImageSpeedClass {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if Self.scripted != nil { return .s1 }
        #endif
        guard let f = await facts() else { return .s1 }
        return ImageSpeedClass(rawValue: f.selection.speedClass.rawValue) ?? .s1
    }

    public func safetyManifest() async -> SafetyManifest? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // A scripted video engine too: its jobs carry the same gate (Q-015 r2: video tests without a scripted image
        // engine had no detectors and every clip failed `safety.missing`).
        if Self.scripted != nil || LaunchOptions.current.scriptedVideoScript != nil {
            let m = SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot)
            // `ANTICHAT_NO_DETECTORS=1`: the files are "not installed" (safety-missing card, repair size kept).
            guard ProcessInfo.processInfo.environment["ANTICHAT_NO_DETECTORS"] == "1", var gone = m else { return m }
            gone.nudityPath = "/nonexistent/csc-nudity"; gone.agePath = "/nonexistent/csc-age"; gone.ageBinsPath = "/nonexistent/csc-age-bins"
            return gone
        }
        #endif
        guard let f = await facts() else { return nil }
        // M4 review: a job always carries the detectors' catalog size, even where the slot is unassigned, so
        // `safety.missing` shows the real repair size (never 0 B).
        return Self.safety(selection: f.selection, catalog: f.catalog, installs: f.installs, requireSlot: false)
    }

    /// NFR-B2: Battery saver in effect (Low Power Mode, low battery on Auto, or chosen; `-FakePower lowpower` in tests).
    public func mediaStepDown() async -> Bool { PowerLaunch.status.effects.mediaStepDown }

    /// M4.T15: the installed `img-erase` (catalog entry `img-erase`, `LaMa.mlpackage` in its install view), nil = not
    /// installed. Dev: `ANTICHAT_ERASE_MODEL` points at a package (the dev model cache's `img-erase/LaMa.mlpackage`).
    public func eraseModelPath() async -> String? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let p = ProcessInfo.processInfo.environment["ANTICHAT_ERASE_MODEL"], FileManager.default.fileExists(atPath: p) { return p }
        #endif
        guard let f = await facts(), f.catalog.models["img-erase"] != nil else { return nil }
        let url = f.installs.appendingPathComponent("img-erase").appendingPathComponent("LaMa.mlpackage")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Manifest.json").path) ? url.path : nil
    }

    /// M4.T13: a picture id of the running tool call's chat (artifact id → its newest version's file, version id → that
    /// version, attachment id → the uploaded file), from the call's store (`ToolCallStore.database`).
    public func imagePath(_ id: String) async -> String? {
        ImageEditFlow.resolve(id, database: ToolCallStore.database, chatID: TurnContext.chatID)?.path
    }

    /// Pure resolution (tests): nil when the slot has no such model or one of its files is not installed.
    static func modelSet(tool: String, selection: Selection, catalog: ModelCatalog, installs: URL) -> ImageModelSet? {
        guard let slot = selection.slots.first(where: { $0.pack == .photo && $0.mode == .normal && $0.role == "photo" }) else { return nil }
        // M4.T13: edit_image's default ("quick") is the create model; "edit_image.best" = the image_edit model (img-edit).
        let role = tool == "edit_image.best" ? "image_edit" : "image"
        guard let id = slot.installIDs.first(where: { k in
            catalog.models[k].map { $0.role == role && !($0.requires ?? []).isEmpty } ?? false
        }), let main = catalog.models[id] else { return nil }
        func path(_ key: String, _ m: CatalogModel, where ok: (String) -> Bool) -> String? {
            guard let f = m.files.first(where: { ok($0.path) }) else { return nil }
            let url = installs.appendingPathComponent(key).appendingPathComponent(f.path)
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        guard let diffusion = path(id, main, where: { $0.hasSuffix(".gguf") }) else { return nil }
        var llm = "", vae = "", vision: String?, loras: [String] = []
        var bytes = UInt64(max(0, main.totalBytes)) + UInt64(main.footprint.overheadGB * 1e9)
        for r in main.requires ?? [] {
            guard let m = catalog.models[r] else { return nil }
            bytes += UInt64(max(0, m.totalBytes))
            if r.contains("lightning") {
                // M4.T13: img-edit's Lightning 4-step LoRA (steps 4 at cfg 1 need it; model-matrix §11.5).
                guard let p = path(r, m, where: { $0.hasSuffix(".safetensors") }) else { return nil }
                loras.append(p)
            } else if r.contains("vae") {
                guard let p = path(r, m, where: { $0.hasSuffix(".safetensors") }) else { return nil }
                vae = p
            } else if r.hasSuffix("-te") || r.contains("-te-") {
                guard let p = path(r, m, where: { $0.hasSuffix(".gguf") && !$0.contains("mmproj") }) else { return nil }
                llm = p
                vision = path(r, m, where: { $0.contains("mmproj") })
            }
        }
        guard !llm.isEmpty, !vae.isEmpty else { return nil }
        return ImageModelSet(key: id, diffusionModel: diffusion, llm: llm, vae: vae, footprintBytes: bytes,
                             extraArgs: vision.map { ["--llm_vision", $0] } ?? [], loras: loras.isEmpty ? nil : loras)
    }

    /// The detector manifest of the `csam_check` slot (nil = not installed: the job fails closed).
    /// `requireSlot` false (jobs): the catalog's detector entries are enough — absent files still give a manifest whose
    /// size is the repair download.
    public static func safety(selection: Selection, catalog: ModelCatalog, installs: URL, requireSlot: Bool = true) -> SafetyManifest? {
        if requireSlot {
            guard let slot = selection.slots.first(where: { $0.role == "csam_check" }), !slot.installIDs.isEmpty else { return nil }
        }
        var paths: [String: String] = [:], sha: [String: String] = [:]
        var size: Int64 = 0
        for (key, file) in SafetyManifestResolver.files {
            guard let m = catalog.models[key], let f = m.files.first(where: { $0.path == file }) else { return nil }
            size += f.size
            paths[key] = installs.appendingPathComponent(key).appendingPathComponent(f.path).path
            sha[key] = f.sha256
        }
        // Absent files still yield a manifest: the gate reports `safetyMissing` with the repair size.
        return SafetyManifest(nudityPath: paths["csc-nudity"]!, agePath: paths["csc-age"]!, ageBinsPath: paths["csc-age-bins"]!,
                              sha256: sha, sizeBytes: size)
    }
}
