// M5.T10: the composition root's `VideoModelProviding` — the Video pack's models (Settings › Capabilities' selection
// over the signed catalog) resolved to their install views `<Models>/installs/<id>/<file>`, and the video runtime
// `<Application Support>/AntiChat/Runtimes/video-runtime@<ver>/` (RuntimeInstaller). A plan job becomes the helper's
// `VideoRequest`:
//   * `vid-5b`: T2V on the FastMetal runtime — model dir + TAEHV (`vid-taehv`, previews + decode); every tier's
//     silent text-to-video model, T4 included (A-M5-13: vid-14b, Wan2.1, is not assigned — it misses NFR-VID1);
//   * `vid-ltx` (Sound on; Normal chats only, K-014): the runtime's LTX engine — model dir + Gemma dir + `audio`;
//   * `vid-i2v`: I2V on sd-server — diffusion GGUF + Wan2.2 VAE + umT5 (`vid-te`) + TAEHV (`vid-taehv`) + the source picture as is
//     (never checked, D-005).
// `-UseScriptedVideoEngine <script.json>` (DEBUG) makes every job the helper's ScriptedVideoEngine (no runtime, no
// model; outputs still pass the gate). Completion posts `MediaJobCompleted` (Platform, R-040 AC2; delivered in M8).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import Defaults
import Foundation

public struct InstalledVideoModels: VideoModelProviding {
    public init() {}

    struct Facts: Sendable {
        var selection: Selection
        var catalog: ModelCatalog
        var profile: HardwareProfile
        var installs: URL
        var installed: Bool
    }

    func facts() async -> Facts? {
        let model = await MainActor.run { PackManagementModel.shared }
        if await MainActor.run(body: { model.selection == nil }) { await model.refresh() }
        return await MainActor.run {
            guard let s = model.selection, let c = model.catalog, let p = model.profile else { return nil }
            return Facts(selection: s, catalog: c, profile: p, installs: DownloadsLaunch.models.installs,
                         installed: model.isInstalled(.video))
        }
    }

    static var scripted: ScriptedVideoScript? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        guard let path = LaunchOptions.current.scriptedVideoScript else { return nil }
        return ScriptedVideoScript.load(path) ?? ScriptedVideoScript()
        #else
        return nil
        #endif
    }

    public func isAvailable() async -> Bool {
        guard let f = await facts() else { return Self.scripted != nil }
        guard VideoEligibility.evaluate(profile: f.profile, selection: f.selection, catalog: f.catalog).isEligible else { return false }
        return f.installed || Self.scripted != nil
    }

    public func speedClass() async -> String { await facts()?.profile.speedClass.rawValue ?? "" }

    public func jobCompleted(chatID: String, jobID: String) async {
        MediaCompletionEvents.jobResult(kind: .video, chatID: chatID, jobID: jobID)
    }

    public func request(for job: VideoPlanJob, sourceImagePath: String?, seed: Int64, isEvil: Bool) async -> VideoRequest? {
        let f = await facts()
        let budget = UInt64(max(0, f?.profile.B ?? 0) * 1e9)
        if let s = Self.scripted {
            var r = Self.base(job, sourceImagePath: sourceImagePath, seed: seed, footprint: 0, budget: budget)
            r.generator = s.generator
            r.yieldToOtherApps = Defaults[.yieldGPU]
            return r
        }
        guard let f else { return nil }
        var r = Self.request(job, sourceImagePath: sourceImagePath, seed: seed, isEvil: isEvil, catalog: f.catalog,
                             installs: f.installs, runtime: Self.runtimeDir(), budget: budget)
        r?.yieldToOtherApps = Defaults[.yieldGPU]  // M5.T11 (NFR-B5): the Advanced setting at submit time
        return r
    }

    /// The fields every job has (size, frames, steps, prompt; output paths are the queue's).
    static func base(_ job: VideoPlanJob, sourceImagePath: String?, seed: Int64, footprint: UInt64, budget: UInt64) -> VideoRequest {
        VideoRequest(mode: job.mode == .i2v ? .i2v : .t2v, prompt: job.prompt, width: job.spec.width, height: job.spec.height,
                     frames: job.spec.frames, fps: job.spec.fps, seed: seed, initImage: sourceImagePath, steps: job.spec.steps,
                     outputPath: "", scratchDir: "", footprintBytes: footprint, memoryLimitBytes: budget)
    }

    /// Pure resolution (tests; `-Bench video --installed`): nil when a needed file is not installed. Evil never runs
    /// LTX (K-014).
    public static func request(_ job: VideoPlanJob, sourceImagePath: String?, seed: Int64, isEvil: Bool, catalog: ModelCatalog,
                        installs: URL, runtime: URL?, budget: UInt64) -> VideoRequest? {
        let key = job.spec.model
        guard let main = catalog.models[key] else { return nil }
        func dir(_ k: String) -> String? {
            let u = installs.appendingPathComponent(k)
            return FileManager.default.fileExists(atPath: u.path) ? u.path : nil
        }
        func file(_ k: String, where ok: (String) -> Bool) -> String? {
            guard let m = catalog.models[k], let f = m.files.first(where: { ok($0.path) }) else { return nil }
            let u = installs.appendingPathComponent(k).appendingPathComponent(f.path)
            return FileManager.default.fileExists(atPath: u.path) ? u.path : nil
        }
        var bytes = UInt64(max(0, main.totalBytes)) + UInt64(main.footprint.overheadGB * 1e9)
        for r in main.requires ?? [] { bytes += UInt64(max(0, catalog.models[r]?.totalBytes ?? 0)) }
        var req = base(job, sourceImagePath: sourceImagePath, seed: seed, footprint: bytes, budget: budget)
        // M5 review P1-1: TAEHV (`vid-taehv`, a `requires` of vid-5b / vid-i2v: preview + final decode, I2V
        // encode/decode) from its install view. Not installed → no request (the card shows unavailable), never a job
        // that fails `taehvMissing` in the runtime or falls back to sd.cpp's unusable full-VAE decode. LTX does not use it.
        if !main.capabilities.contains(VideoSound.capability) {
            guard let taehv = (main.requires ?? []).lazy.compactMap({ k in file(k, where: { $0.hasSuffix("taew2_2.safetensors") }) }).first
            else { return nil }
            req.taehv = taehv
        }
        if job.mode == .i2v {
            guard sourceImagePath != nil,
                  let diffusion = file(key, where: { $0.hasSuffix(".gguf") }),
                  let vae = file(key, where: { $0.hasSuffix(".safetensors") && $0.lowercased().contains("vae") }),
                  let te = (main.requires ?? []).lazy.compactMap({ k in file(k, where: { $0.hasSuffix(".gguf") }) }).first else { return nil }
            req.diffusionModel = diffusion
            req.vae = vae
            req.t5xxl = te
            req.cfgScale = 6
            req.flowShift = 3
            return req
        }
        guard let runtime, let modelDir = dir(key) else { return nil }
        req.runtimeDir = runtime.path
        req.modelDir = modelDir
        if main.capabilities.contains(VideoSound.capability) {
            guard !isEvil, let te = (main.requires ?? []).first, let gemma = dir(te) else { return nil }
            req.modelKind = "ltx"
            req.gemmaDir = gemma
            req.audio = job.spec.sound
        }
        return req
    }

    /// The newest installed video runtime folder (`video-runtime@<ver>`), nil when none.
    static func runtimeDir(paths: RuntimePaths = .default()) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: paths.root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("video-runtime@") }
            .max { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
    }
}
