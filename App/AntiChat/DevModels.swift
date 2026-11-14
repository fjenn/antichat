// Dev model lookup for the M0 spikes (M0.md C6): `~/Library/Application Support/AntiChat-Dev/Models/<key>`
// (or `$ANTICHAT_DEV_CACHE/Models`); since M2.T12 the install views `installs/<key>` of the content-addressed store
// first (`make models-dev` → antichat-cli), the old `<Models>/<key>` dirs only for the M0 image/video spike sets.
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation

enum DevModels {
    /// Tier budgets B in GB (hardware-tiers.md §2.2; M0.md C5). 1 GB = 1e9 bytes.
    static let tierB: [String: Double] = [
        "T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48, "none": 0,
    ]

    static var modelsDir: URL {
        if let c = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"], !c.isEmpty {
            return URL(fileURLWithPath: c).appendingPathComponent("Models")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }

    /// M2.T12 (A-M2-T10a (d)): the content-addressed install view `<Models>/installs/<key>` that `make models-dev`
    /// materialises, else the pre-M2 `<Models>/<key>` layout.
    static func view(_ key: String) -> URL {
        let v = modelsDir.appendingPathComponent("installs").appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: v.appendingPathComponent("manifest.json").path) ? v : modelsDir.appendingPathComponent(key)
    }

    /// A voice role's model folder (`VoiceModelRole.developerDirectory`: by catalog key, so `turn` is `turn-coreml`,
    /// never the ONNX `installs/turn`); nil when it is not installed.
    static func voiceView(_ role: VoiceModelRole) -> URL? { role.developerDirectory(in: modelsDir) }

    /// The dev voice set of `roles` as the helper's `VoiceModelSet` (missing roles absent).
    static func voiceSet(_ roles: [VoiceModelRole]) -> VoiceModelSet {
        var slots: [VoiceModelRole: ModelSlot] = [:]
        for role in roles {
            guard let v = voiceView(role) else { continue }
            slots[role] = ModelSlot(engine: .coreml, key: role.catalogKey, path: v.path, footprintBytes: directorySize(v))
        }
        return VoiceModelSet(slots: slots)
    }

    /// Families loaded through VLMModelFactory (K-NEW-MOD-5 step 13).
    static let visionKeys: Set<String> = ["chat-g12", "chat-35b-q4-vision"]

    static func directorySize(_ url: URL) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e {
            // Install views are symlinks into the store: count the blob, not the link.
            total += UInt64((try? f.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// M0.T06 image sets (model-matrix §1, §2.2): T1 = img-klein Q4_0 + img-te Q4_K_M + flux2 VAE;
    /// T2 = img-klein Q8_0 + img-te Q8_0 + flux2 VAE, started with `--params-backend te=disk --max-vram 7`
    /// (disk-backed text encoder evicted under a 7 GiB managed budget) so it co-resides with chat-9b-q4 inside
    /// B = 16 GB (R-236; S-5 report, A-M0-T06a). Footprints = sd-server peak `phys_footprint` measured by the
    /// M0.T06 probes at that resolution + ~5% [measured on M5 Max; feeds the G-011 footprint table].
    static func imageSet(_ quant: String, res: Int) -> ImageModelSet {
        let d = modelsDir
        let q8 = quant == "q8"
        let table: [String: Double] = ["q4@768": 6.3, "q4@1024": 6.0, "q8@768": 6.2, "q8@1024": 6.2]
        let gb = ProcessInfo.processInfo.environment["ANTICHAT_IMG_FOOTPRINT_GB"].flatMap(Double.init) ?? table["\(quant)@\(res)"] ?? 7
        return ImageModelSet(
            key: q8 ? "img-klein-q8" : "img-klein-q4",
            diffusionModel: d.appendingPathComponent("img-klein/flux-2-klein-4b-\(q8 ? "Q8_0" : "Q4_0").gguf").path,
            llm: d.appendingPathComponent("img-te/Qwen3-4B-\(q8 ? "Q8_0" : "Q4_K_M").gguf").path,
            vae: d.appendingPathComponent("img-vae-flux2/split_files/vae/flux2-vae.safetensors").path,
            footprintBytes: UInt64(gb * 1e9),
            extraArgs: (ProcessInfo.processInfo.environment["ANTICHAT_SD_ARGS"] ?? (q8 ? "--params-backend te=disk --max-vram 7" : ""))
                .split(separator: " ").map(String.init))
    }

    /// M2.T15: the Evil chat slot when its files are installed (nil otherwise: Evil shows `evil.notAvailablePack`).
    static func evilSlot(_ key: String) -> ModelSlot? {
        let k = key.hasPrefix("llama:") ? String(key.dropFirst(6)) : key
        guard FileManager.default.fileExists(atPath: view(k).path) else { return nil }
        return slot(key)
    }

    /// `key` = model-matrix key (MLX dir), `gguf:<path>` (llama-server), `llama:<key>` (a GGUF model dir under
    /// the models dir: model + optional mmproj, router model name = dir name; M0.T09), or `<key>+vision`.
    static func slot(_ key: String) -> ModelSlot {
        if key.hasPrefix("llama:") {
            let k = String(key.dropFirst(6))
            let dir = view(k)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let hasMMProj = files.contains { $0.lowercased().contains("mmproj") && $0.hasSuffix(".gguf") }
            // Catalog footprint ≈ GGUF weights (+ mmproj) × 1.1; KV at 16K on the hybrid Qwen3.5 is small [ASSUMPTION].
            let weights = files.filter { $0.hasSuffix(".gguf") }.reduce(UInt64(0)) {
                $0 + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($1).resolvingSymlinksInPath().path)[.size] as? UInt64) ?? 0)
            }
            return ModelSlot(engine: .llama, key: k, path: dir.path, footprintBytes: UInt64(Double(weights) * 1.1), vision: hasMMProj,
                contextTokens: 16384)
        }
        if key.hasPrefix("gguf:") {
            let path = String(key.dropFirst(5))
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            return ModelSlot(engine: .llama, key: URL(fileURLWithPath: path).lastPathComponent, path: path, footprintBytes: size)
        }
        var k = key
        var vision = visionKeys.contains(key)
        if k.hasSuffix("+vision") {
            k = String(k.dropLast(7))
            vision = true
        }
        let dir = view(k)
        // Catalog footprint ≈ weights × 1.1 (KV at 1–4K context is small at M0's contexts) [ASSUMPTION].
        let weights = directorySize(dir)
        return ModelSlot(engine: .mlx, key: vision ? "\(k)+vision" : k, path: dir.path, footprintBytes: UInt64(Double(weights) * 1.1), vision: vision)
    }

    /// M2.T16: a search-model slot (`embed` / `rerank`) when its install view exists, else nil (FTS-only search).
    static func searchSlot(_ key: String) -> ModelSlot? {
        let dir = view(key)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return nil }
        return slot(key)
    }
}
