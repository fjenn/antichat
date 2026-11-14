// Image requests and events (M0.T06 spike, S-5; architecture.md §4.3 "Image" lane, D-013).
// The helper runs `Contents/Helpers/sd-server` as a child; the scheduler in the helper is the single load
// authority, so an image request carries everything the scheduler needs to fit-or-evict (footprint) and
// to restore the chat model afterwards (NFR-M3). Large payloads (PNG bytes) never cross XPC: the helper
// writes the final image to `outputPath` and reports its hash.
import Foundation

/// The files of one sd.cpp model set (model-matrix §1: img-klein + img-te + img-vae-flux2).
public struct ImageModelSet: Codable, Sendable, Hashable {
    /// Catalog key of the set, e.g. `img-klein-q4` (one sd-server context).
    public var key: String
    public var diffusionModel: String
    public var llm: String
    public var vae: String
    /// Peak bytes while generating at the default resolution (weights + activations); the scheduler's
    /// fit-or-evict input (hardware-tiers §2.4 T1 row).
    public var footprintBytes: UInt64
    /// Extra sd-server startup flags (recorded in the S-5 report).
    public var extraArgs: [String]
    /// M4.T13: LoRA files applied to every job of the set (img-edit: the Lightning 4-step LoRA, model-matrix §11.5);
    /// sd-server gets `--lora-model-dir` (their directory) and each request names them in `lora` (api.md "LoRA Rules").
    public var loras: [String]?

    public init(key: String, diffusionModel: String, llm: String, vae: String, footprintBytes: UInt64, extraArgs: [String] = [],
                loras: [String]? = nil) {
        self.key = key
        self.diffusionModel = diffusionModel
        self.llm = llm
        self.vae = vae
        self.footprintBytes = footprintBytes
        self.extraArgs = extraArgs
        self.loras = loras
    }
}

public struct ImageRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var model: ImageModelSet
    public var prompt: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seed: Int64
    public var cfgScale: Float
    public var sampleMethod: String
    /// sd.cpp preview mode: `none`, `proj`, `tae`, `vae` (stable-diffusion.h `preview_t`).
    public var preview: String
    /// The helper writes the final PNG here (spike: `build/at/AT-M0-06/out/`, never shown in the UI).
    public var outputPath: String
    /// Chat model to make resident again after the job when it had to be evicted (NFR-M3 reload).
    public var restoreChat: ModelSlot?
    /// M4.T04: the detector files for the bench lane (`ClientMessage.image`); every image output passes the gate,
    /// so nil ⇒ `safetyMissing` and no file. Queue jobs carry theirs in `MediaJobSubmit.safety`.
    public var safety: SafetyManifest?
    /// M4.T06: sent only when the catalog entry uses one (R-286 AC3); nil = the field is omitted.
    public var negativePrompt: String?
    /// M4.T06 edits (M4.T13): the source picture and an optional mask (PNG files the app owns).
    public var initImagePath: String?
    public var maskImagePath: String?
    /// M4.T13: reference pictures (sd-server `ref_images`): an instruction edit hands the source here (FLUX.2-klein
    /// multi-reference edit; Qwen-Image-Edit reads it through the `--llm_vision` mmproj). nil = none.
    public var refImagePaths: [String]?
    /// M4.T13 fallback (klein drift on T1/T2): img2img denoising strength with `initImagePath` (sd-server `strength`).
    public var strength: Float?
    /// M4.T15: a `local` job (`MediaJobKind.local`): the operation the helper runs itself instead of sd-server
    /// (`removeBackground` = Vision foreground mask; `erase` = LaMa on `initImagePath` + `maskImagePath`). Its one
    /// result passes the gate like any Photo output.
    public var localOperation: String?
    /// M4.T07 step 6 (NFR-B2): Low Power Mode / Battery saver dropped the resolution one step (recorded in the job spec).
    public var lowPower: Bool?

    public init(
        requestID: UUID = UUID(), model: ImageModelSet, prompt: String, width: Int, height: Int, steps: Int = 4,
        seed: Int64, cfgScale: Float = 1, sampleMethod: String = "euler", preview: String = "proj", outputPath: String,
        restoreChat: ModelSlot? = nil, safety: SafetyManifest? = nil
    ) {
        self.safety = safety
        self.requestID = requestID
        self.model = model
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.cfgScale = cfgScale
        self.sampleMethod = sampleMethod
        self.preview = preview
        self.outputPath = outputPath
        self.restoreChat = restoreChat
    }
}

public struct ImageProgress: Codable, Sendable, Hashable {
    public var pass: Int
    public var step: Int
    public var totalSteps: Int
    /// Size and hash prefix of the preview PNG of this step (the bytes stay in the helper).
    public var previewBytes: Int
    public var previewSHA256: String
    public var sdServerPID: Int32

    public init(pass: Int, step: Int, totalSteps: Int, previewBytes: Int, previewSHA256: String, sdServerPID: Int32) {
        self.pass = pass
        self.step = step
        self.totalSteps = totalSteps
        self.previewBytes = previewBytes
        self.previewSHA256 = previewSHA256
        self.sdServerPID = sdServerPID
    }
}

/// What the scheduler did around a job (fit-or-evict decisions and their timings).
public struct SchedulerNote: Codable, Sendable, Hashable {
    /// `evicted`, `kept`, `imageLoaded`, `imageUnloaded`, `chatReloaded`, `cancelled`, `sdStarted`.
    public var action: String
    public var model: String
    public var seconds: Double
    public var detail: [String: String]

    public init(action: String, model: String, seconds: Double = 0, detail: [String: String] = [:]) {
        self.action = action
        self.model = model
        self.seconds = seconds
        self.detail = detail
    }
}

public struct ImageResult: Codable, Sendable, Hashable {
    /// `completed`, `cancelled`, or (M4.T04, the gate withheld it: no file) `blocked` / `safetyMissing`.
    public var status: String
    public var path: String
    public var width: Int
    public var height: Int
    public var sha256: String
    public var bytes: Int
    /// Timings in seconds and byte counts (keys documented in BenchMode / the S-5 report).
    public var metrics: [String: Double]

    public init(status: String, path: String, width: Int, height: Int, sha256: String, bytes: Int, metrics: [String: Double]) {
        self.status = status
        self.path = path
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.bytes = bytes
        self.metrics = metrics
    }
}
