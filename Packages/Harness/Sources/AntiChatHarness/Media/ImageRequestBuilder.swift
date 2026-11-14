// M4.T06 step 2 (R-286 AC1/AC3): a validated `create_image` / `edit_image` call + the installed photo model → the
// helper's `ImageRequest` (sd-server fields, SDServerAPI.md). App side, because the request carries the installed
// file paths. Resolution from the aspect at equal pixel count — base 768² on speed classes S1/S2, 1024² on S3/S4 —
// sides rounded to multiples of 64; steps / cfg / sampler / `model_args` from the model's profile; the seed is the
// call's or a random one (recorded in the request and the result metadata); `negative_prompt` is sent ONLY when the
// model uses one (FLUX.2-klein, Z-Image-Turbo and Qwen-Image-Edit + Lightning at cfg 1 do not: their cards run
// distilled / cfg-free sampling, where a negative prompt is ignored or harmful).
import AntiChatEngineProtocol
import AntiChatTools
import Foundation

/// Generation settings of one photo model family (model cards; A-M4-T06a: kept here keyed by catalog key until the
/// catalog schema carries them).
public struct ImageModelProfile: Sendable, Equatable {
    public var usesNegativePrompt: Bool
    public var steps: Int
    public var cfg: Float
    public var sampler: String
    /// sd-server `--model-args` (img-edit: `qwen_image_zero_cond_t=true`, A-M4-04).
    public var modelArgs: [String]

    public init(usesNegativePrompt: Bool, steps: Int, cfg: Float, sampler: String = "euler", modelArgs: [String] = []) {
        self.usesNegativePrompt = usesNegativePrompt
        self.steps = steps
        self.cfg = cfg
        self.sampler = sampler
        self.modelArgs = modelArgs
    }

    /// M9.T05 (AT-NFR-P4, A-M9-T05-P4): img-edit keeps sd.cpp's reference default (min(1 MP, output)). A capped
    /// reference latent (`--ref-image-args vae_input_max_pixels`) would cut the DiT sequence (a 1024² reference doubles
    /// a 1024² job's tokens), but blind A/Bs at 576² and 768² showed the model recomposing unchanged regions (zoom-out,
    /// reframing, garbled text) on every golden while 1 MP stayed faithful, so no cap is set.
    /// By catalog key prefix. klein: 4-step distilled (FLUX.2 [klein] card, guidance 1); Z-Image-Turbo: 8 NFE, cfg-free
    /// (Tongyi-MAI card); Qwen-Image-Edit-2511 + Lightning 4-step LoRA at cfg 1 (lightx2v card; sd.cpp
    /// `docs/qwen_image_edit.md@e239e4b`).
    public static func forKey(_ key: String) -> ImageModelProfile {
        if key.hasPrefix("img-zit") { return ImageModelProfile(usesNegativePrompt: false, steps: 8, cfg: 1) }
        if key.hasPrefix("img-edit") {
            return ImageModelProfile(usesNegativePrompt: false, steps: 4, cfg: 1,
                                     modelArgs: ["--model-args", "qwen_image_zero_cond_t=true"])
        }
        if key.hasPrefix("scripted") { return ImageModelProfile(usesNegativePrompt: false, steps: 4, cfg: 1) }
        return ImageModelProfile(usesNegativePrompt: false, steps: 4, cfg: 1)  // img-klein-*
    }
}

public enum ImageSpeedClass: String, Sendable, CaseIterable {
    case s1 = "S1", s2 = "S2", s3 = "S3", s4 = "S4"
    public var baseSide: Int { self == .s1 || self == .s2 ? 768 : 1024 }
}

public enum ImageRequestBuilder {
    public struct Call: Sendable, Equatable {
        public var prompt: String
        public var negativePrompt: String?
        public var aspect: String
        public var style: String?
        public var seed: Int64?
        public var mode: String
        public var sourceImageID: String?
        public var maskID: String?
        /// The call named an aspect (an edit otherwise keeps the source's, M4.T13).
        public var aspectGiven = false
        /// Edit quality for this call (`quick` default; `best` from `TurnContext.imageEditBest` = img-edit where installed).
        public var quality = "quick"
    }

    public enum BuildError: Error, Equatable { case badArguments(String) }

    /// Parses the tool arguments (already schema-checked by the tool loop; tolerant of absent optionals).
    public static func parse(_ argumentsJSON: String, tool: String) throws -> Call {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            throw BuildError.badArguments("not a JSON object")
        }
        guard let prompt = (o["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw BuildError.badArguments("prompt is required")
        }
        let aspect = (o["aspect"] as? String).flatMap { CreateImageTool.aspects.contains($0) ? $0 : nil } ?? "1:1"
        let seed = (o["seed"] as? NSNumber)?.int64Value
        let mode = (o["mode"] as? String) ?? (tool == EditImageTool.name ? "edit" : "generate")
        let source = o["source_image_id"] as? String
        if tool == EditImageTool.name, source == nil { throw BuildError.badArguments("source_image_id is required") }
        return Call(prompt: prompt, negativePrompt: (o["negative_prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }, aspect: aspect,
                    style: (o["style"] as? String).flatMap { $0.isEmpty ? nil : $0 }, seed: seed, mode: mode,
                    sourceImageID: source, maskID: o["mask_id"] as? String,
                    aspectGiven: (o["aspect"] as? String).map(CreateImageTool.aspects.contains) ?? false)
    }

    /// Width × height for `aspect` at the speed class's pixel count, multiples of 64.
    /// `stepDown` (Low Power Mode / Battery saver, NFR-B2): one resolution step lower — 1024² → 768² → 640² equal-area.
    public static func resolution(aspect: String, speed: ImageSpeedClass, stepDown: Bool = false) -> (width: Int, height: Int) {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        let ratio = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
        let side = stepDown ? (speed.baseSide > 768 ? 768 : 640) : speed.baseSide
        let area = Double(side * side)
        func r64(_ x: Double) -> Int { max(64, Int((x / 64).rounded()) * 64) }
        return (r64((area * ratio).squareRoot()), r64((area / ratio).squareRoot()))
    }

    /// The request for `call` on `model` (output and previews go where the queue puts them). `livePreviews` false
    /// (T0–T2, `ImageTurnPolicy.livePreviews`) → `preview: none`: progress only, the generator unloads before the one
    /// final check.
    public static func request(_ call: Call, model: ImageModelSet, speed: ImageSpeedClass,
                               profile: ImageModelProfile? = nil, livePreviews: Bool = true, stepDown: Bool = false,
                               initImagePath: String? = nil,
                               maskImagePath: String? = nil,
                               randomSeed: () -> Int64 = { Int64.random(in: 1...Int64(Int32.max)) }) -> ImageRequest {
        let p = profile ?? ImageModelProfile.forKey(model.key)
        let (w, h) = resolution(aspect: call.aspect, speed: speed, stepDown: stepDown)
        var set = model
        for a in p.modelArgs where !set.extraArgs.contains(a) { set.extraArgs.append(a) }
        let prompt = call.style.map { "\(call.prompt), \($0)" } ?? call.prompt
        var r = ImageRequest(model: set, prompt: prompt, width: w, height: h, steps: p.steps, seed: call.seed ?? randomSeed(),
                             cfgScale: p.cfg, sampleMethod: p.sampler, preview: livePreviews ? "proj" : "none",
                             outputPath: "")
        r.negativePrompt = p.usesNegativePrompt ? (call.negativePrompt ?? "") : nil
        if stepDown { r.lowPower = true }  // recorded in the job spec (NFR-B2)
        r.initImagePath = initImagePath
        r.maskImagePath = maskImagePath
        return r
    }
}
