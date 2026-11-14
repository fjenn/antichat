// Video requests and events (M0.T07 spike, S-10; architecture.md §4.3, D-013, P-media-11).
// T2V runs our Wan2.2 driver (M0.T07: `antichat_video.generate_wan22`; since M5.T02 the runtime server, M5.T14 removed the driver) in the video runtime's python as a child of the
// helper; I2V runs `sd-cli -M vid_gen` (stable-diffusion.cpp@e239e4b). Large payloads never cross XPC: the
// helper writes the MP4 to `outputPath` and preview PNGs to `scratchDir`, and reports paths and hashes.
import Foundation

public struct VideoRequest: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable { case t2v, i2v }

    public var requestID: UUID
    public var mode: Mode
    public var prompt: String
    public var width: Int
    public var height: Int
    /// Pixel frames (4k + 1).
    public var frames: Int
    public var fps: Int
    public var seed: Int64
    /// T2V: video runtime root (`bin/python3`), FastMetal `vid-5b` dir, TAEHV `.safetensors`.
    public var runtimeDir: String
    public var modelDir: String
    public var taehv: String
    /// I2V (sd.cpp): `sd-cli` binary, diffusion GGUF, Wan2.2 VAE, umT5 GGUF, init image, sampler steps, cfg.
    public var sdCLI: String
    public var diffusionModel: String
    public var vae: String
    public var t5xxl: String
    public var initImage: String?
    public var steps: Int
    public var cfgScale: Float
    public var flowShift: Float
    /// Output MP4 (spike: `build/at/AT-M0-07/out/`, never shown in a UI) and the job scratch dir (previews, frames).
    public var outputPath: String
    public var scratchDir: String
    /// Peak bytes of the job (scheduler fit-or-evict input; T2V measured 11.1 GiB TE stage, M0.T07).
    public var footprintBytes: UInt64
    /// Passed to MLX as its memory limit (the tier budget B; 0 = none).
    public var memoryLimitBytes: UInt64
    /// M5.T03: the job runs through the helper's MediaJobRunner like an image job — the ChildSafetyCheck detector files
    /// (nil ⇒ every output `safetyMissing`) and the dir where allowed previews are written (after the gate).
    public var safety: SafetyManifest?
    public var previewDir: String?
    /// M5.T03 test double: `scripted` runs the runtime's scripted generator (no model; ScriptedVideoEngine).
    public var generator: String?
    /// M5.T07 (R-292): `ltx` = LTX-2.3 with a sound track (`modelDir` = vid-ltx, `gemmaDir` = vid-ltx-te); nil = Wan2.2.
    public var modelKind: String?
    public var gemmaDir: String?
    /// "Sound on": keep and mux the generated sound track (LTX only; Normal chats only, K-014).
    public var audio: Bool?
    /// M5.T11 (NFR-B5): Settings › Capabilities › Advanced "Pause video jobs when another app needs the GPU" at submit
    /// time (nil = on, the default). Off: the job still drops to background priority, it just keeps running.
    public var yieldToOtherApps: Bool?

    public init(
        requestID: UUID = UUID(), mode: Mode, prompt: String, width: Int, height: Int, frames: Int, fps: Int = 24,
        seed: Int64, runtimeDir: String = "", modelDir: String = "", taehv: String = "", sdCLI: String = "",
        diffusionModel: String = "", vae: String = "", t5xxl: String = "", initImage: String? = nil, steps: Int = 20,
        cfgScale: Float = 6, flowShift: Float = 3, outputPath: String, scratchDir: String, footprintBytes: UInt64,
        memoryLimitBytes: UInt64 = 0, safety: SafetyManifest? = nil, previewDir: String? = nil, generator: String? = nil
    ) {
        self.requestID = requestID
        self.mode = mode
        self.prompt = prompt
        self.width = width
        self.height = height
        self.frames = frames
        self.fps = fps
        self.seed = seed
        self.runtimeDir = runtimeDir
        self.modelDir = modelDir
        self.taehv = taehv
        self.sdCLI = sdCLI
        self.diffusionModel = diffusionModel
        self.vae = vae
        self.t5xxl = t5xxl
        self.initImage = initImage
        self.steps = steps
        self.cfgScale = cfgScale
        self.flowShift = flowShift
        self.outputPath = outputPath
        self.scratchDir = scratchDir
        self.footprintBytes = footprintBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.safety = safety
        self.previewDir = previewDir
        self.generator = generator
    }
}

/// One progress event of a video job: a stage change (`step == 0`) or a finished sampler step.
public struct VideoProgress: Codable, Sendable, Hashable {
    /// `spawn`, `encode`, `load`, `denoise`, `decode`, `write`, `mux`, or `step`.
    public var stage: String
    public var step: Int
    public var totalSteps: Int
    /// Seconds since the job was submitted (helper clock).
    public var t: Double
    /// Preview PNG of this step (a file in the scratch dir; bytes stay in the helper) + its size and hash prefix.
    public var previewPath: String?
    public var previewBytes: Int
    public var previewSHA256: String
    public var childPID: Int32

    public init(stage: String, step: Int = 0, totalSteps: Int = 0, t: Double, previewPath: String? = nil,
                previewBytes: Int = 0, previewSHA256: String = "", childPID: Int32) {
        self.stage = stage
        self.step = step
        self.totalSteps = totalSteps
        self.t = t
        self.previewPath = previewPath
        self.previewBytes = previewBytes
        self.previewSHA256 = previewSHA256
        self.childPID = childPID
    }
}

public struct VideoResult: Codable, Sendable, Hashable {
    /// `completed`, `cancelled` or `failed`.
    public var status: String
    public var path: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var sha256: String
    public var bytes: Int
    /// Timings (s) and byte counts; keys documented in the S-10 report.
    public var metrics: [String: Double]

    public init(status: String, path: String, width: Int, height: Int, frames: Int, sha256: String, bytes: Int,
                metrics: [String: Double]) {
        self.status = status
        self.path = path
        self.width = width
        self.height = height
        self.frames = frames
        self.sha256 = sha256
        self.bytes = bytes
        self.metrics = metrics
    }
}
