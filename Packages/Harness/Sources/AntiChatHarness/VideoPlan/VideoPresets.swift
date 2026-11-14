// M5.T09 step 1 (R-044 AC1/AC2, G-045; hardware-tiers §4.4; P-media-12, resolution/aspect validation after
// osaurus@2922745 `LocalVideoRequestPolicy`, written from the patch description): what the plan card may offer on this
// Mac, and the exact job a pick becomes.
//   * The user picks length (short / medium, only where the tier allows) and shape (square / portrait / landscape).
//   * Resolution, steps and exact length come from the tier × speed-class entry of `catalog/video-presets.yaml`
//     (bundled as `video-presets.json`, A-M5-10) and change only in Settings → Capabilities → Advanced → Video
//     (`VideoAdvanced`).
//   * Every spec is valid for the model the job runs on: sides snapped to the model's multiple (Wan2.2 FastMetal 32,
//     LTX 64; ≤ 1920, the runtime's limit) and frames to its 4k+1 / 8k+1 grid.
//   * T2-S1 ("Shown-lite"): text-to-video 480p Short only; image-to-video is not offered (lead decision, M5.T09).
// The estimate scales the closest measured speed-table row of the same model and mode (VideoEstimator) by pixels and
// latent frames; a model without rows has no estimate.
import Foundation

public enum VideoLength: String, Codable, Sendable, CaseIterable, Hashable {
    case short, medium
    public var copyKey: String { "video.length.\(rawValue)" }
}

public enum VideoShape: String, Codable, Sendable, CaseIterable, Hashable {
    case square, portrait, landscape
    public var copyKey: String { "video.shape.\(rawValue)" }
}

public enum VideoMode: String, Codable, Sendable, Hashable {
    /// Text-to-video.
    case t2v
    /// Image-to-video (Animate / an attached image).
    case i2v
}

/// Settings → Capabilities → Advanced → Video (R-044 AC2). 0 / "" = the tier's preset.
public struct VideoAdvanced: Sendable, Equatable {
    /// Denoise steps of the tier's text-to-video model (clamped to the model's range; other models keep theirs).
    public var steps: Int
    /// "480p" / "720p" / "1080p" (only values the tier allows apply).
    public var resolution: String
    /// Exact length in whole seconds (snapped to the model's frame grid, bounded by the tier's `max_frames`).
    public var seconds: Int

    public init(steps: Int = 0, resolution: String = "", seconds: Int = 0) {
        self.steps = steps; self.resolution = resolution; self.seconds = seconds
    }

    public static let none = VideoAdvanced()
    public var isEmpty: Bool { steps <= 0 && resolution.isEmpty && seconds <= 0 }
}

/// `video-presets.json`.
public struct VideoPresetsTable: Codable, Sendable, Equatable {
    public struct Resolution: Codable, Sendable, Equatable {
        public var name: String
        public var landscape: [Int]
        public var portrait: [Int]
        public var square: [Int]
        public func size(_ shape: VideoShape) -> (width: Int, height: Int) {
            let s = switch shape { case .landscape: landscape; case .portrait: portrait; case .square: square }
            return (s.first ?? 0, s.count > 1 ? s[1] : 0)
        }
    }

    public struct Frames: Codable, Sendable, Equatable {
        public var resolution: String
        public var short: Int
        public var medium: Int
        public func frames(_ l: VideoLength) -> Int { l == .short ? short : medium }
    }

    public struct ModelRule: Codable, Sendable, Equatable {
        public var key: String
        /// Width and height must be multiples of this.
        public var multiple: Int
        /// Frames must be `frameStep × k + 1`.
        public var frameStep: Int
        public var steps: Int
        public var stepsMin: Int
        public var stepsMax: Int
        enum CodingKeys: String, CodingKey {
            case key, multiple, frameStep = "frame_step", steps, stepsMin = "steps_min", stepsMax = "steps_max"
        }
        public init(key: String, multiple: Int, frameStep: Int, steps: Int, stepsMin: Int, stepsMax: Int) {
            self.key = key; self.multiple = multiple; self.frameStep = frameStep; self.steps = steps
            self.stepsMin = stepsMin; self.stepsMax = stepsMax
        }
        /// An unknown model gets the strictest grid (valid for Wan2.2 and LTX alike).
        public static func fallback(_ key: String) -> ModelRule {
            ModelRule(key: key, multiple: 64, frameStep: 8, steps: 3, stepsMin: 3, stepsMax: 3)
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var tier: String
        public var speedClass: String
        public var lengths: [VideoLength]
        public var resolutions: [String]
        public var i2vResolutions: [String]
        public var defaultLength: VideoLength
        public var defaultResolution: String
        public var defaultShape: VideoShape
        public var maxFrames: Int
        public var t2vModel: String
        public var note: String?
        enum CodingKeys: String, CodingKey {
            case tier, speedClass = "speed_class", lengths, resolutions, i2vResolutions = "i2v_resolutions"
            case defaultLength = "default_length", defaultResolution = "default_resolution", defaultShape = "default_shape"
            case maxFrames = "max_frames", t2vModel = "t2v_model", note
        }
        /// "Shown-lite" (T2-S1).
        public var lite: Bool { note == "Shown-lite" }
    }

    public var schema: Int
    public var fps: Int
    public var resolutions: [Resolution]
    public var frames: [Frames]
    public var models: [ModelRule]
    public var tiers: [Entry]

    public func entry(tier: String, speedClass: String) -> Entry? {
        tiers.first { $0.tier == tier && $0.speedClass == speedClass }
    }
    public func resolution(_ name: String) -> Resolution? { resolutions.first { $0.name == name } }
    public func rule(_ model: String) -> ModelRule { models.first { $0.key == model } ?? .fallback(model) }

    /// The bundled table (empty when the resource is missing: nothing is offered).
    public static let bundled: VideoPresetsTable = {
        guard let url = Bundle.module.url(forResource: "video-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(VideoPresetsTable.self, from: data) else {
            return VideoPresetsTable(schema: 1, fps: 24, resolutions: [], frames: [], models: [], tiers: [])
        }
        return t
    }()
}

/// One resolved job: what the runtime gets (M5.T10 maps it to `VideoRequest`).
public struct VideoSpec: Sendable, Equatable {
    public var model: String
    public var mode: VideoMode
    public var length: VideoLength
    public var shape: VideoShape
    /// "480p" / "720p" / "1080p".
    public var resolution: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var fps: Int
    public var steps: Int
    /// The job keeps a sound track (Sound on, an audio model).
    public var sound: Bool

    public var seconds: Double { fps > 0 ? Double(frames) / Double(fps) : 0 }
    /// width / height.
    public var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
}

/// What the picker offers for one mode on this Mac.
public struct VideoPresetOptions: Sendable, Equatable {
    public var lengths: [VideoLength]
    public var shapes: [VideoShape]
    public var defaultLength: VideoLength
    public var defaultShape: VideoShape
    public var resolution: String
    public var lite: Bool
}

public enum VideoPresets {
    /// The runtime's largest side (antichat_video.protocol: width/height ≤ 1920).
    public static let maxSide = 1920
    /// The runtime's largest clip (num_frames ≤ 241).
    public static let maxFrames = 241

    /// What the plan card may offer for `mode` on this tier × speed class (nil = not offered: T0/T1, or I2V on T2-S1).
    public static func options(tier: String, speedClass: String, mode: VideoMode,
                               table: VideoPresetsTable = .bundled) -> VideoPresetOptions? {
        guard let e = table.entry(tier: tier, speedClass: speedClass), let res = resolution(e, mode: mode, advanced: .none) else {
            return nil
        }
        return VideoPresetOptions(lengths: e.lengths, shapes: VideoShape.allCases,
                                  defaultLength: e.lengths.contains(e.defaultLength) ? e.defaultLength : e.lengths.first ?? .short,
                                  defaultShape: e.defaultShape, resolution: res, lite: e.lite)
    }

    /// The tier's resolution for `mode`: Advanced's pick when the tier allows it, else the default (I2V: its own list).
    static func resolution(_ e: VideoPresetsTable.Entry, mode: VideoMode, advanced: VideoAdvanced) -> String? {
        let allowed = mode == .t2v ? e.resolutions : e.i2vResolutions
        guard !allowed.isEmpty else { return nil }
        if allowed.contains(advanced.resolution) { return advanced.resolution }
        return allowed.contains(e.defaultResolution) ? e.defaultResolution : allowed.last
    }

    /// The exact job for a pick, valid for `model` (nil = the mode is not offered here).
    public static func resolve(tier: String, speedClass: String, mode: VideoMode, model: String,
                               length: VideoLength? = nil, shape: VideoShape? = nil, sound: Bool = false,
                               advanced: VideoAdvanced = .none, table: VideoPresetsTable = .bundled) -> VideoSpec? {
        guard let e = table.entry(tier: tier, speedClass: speedClass),
              let resName = resolution(e, mode: mode, advanced: advanced), let res = table.resolution(resName) else { return nil }
        let rule = table.rule(model)
        let len = length.flatMap { e.lengths.contains($0) ? $0 : nil } ?? (e.lengths.contains(e.defaultLength) ? e.defaultLength : .short)
        let shp = shape ?? e.defaultShape
        let (w0, h0) = res.size(shp)
        let fps = table.fps
        var frames = table.frames.first { $0.resolution == resName }?.frames(len) ?? 73
        if advanced.seconds > 0 { frames = advanced.seconds * fps + 1 }
        frames = snapFrames(frames, step: rule.frameStep, max: min(e.maxFrames, maxFrames))
        var steps = rule.steps
        if advanced.steps > 0, model == e.t2vModel { steps = min(max(advanced.steps, rule.stepsMin), rule.stepsMax) }
        return VideoSpec(model: model, mode: mode, length: len, shape: shp, resolution: resName,
                         width: snapSide(w0, multiple: rule.multiple), height: snapSide(h0, multiple: rule.multiple),
                         frames: frames, fps: fps, steps: steps, sound: sound)
    }

    /// Nearest multiple of `multiple`, at least one multiple, at most `maxSide` (rounded down onto the grid).
    public static func snapSide(_ x: Int, multiple m: Int) -> Int {
        guard m > 0 else { return x }
        let top = (maxSide / m) * m
        let r = Int((Double(x) / Double(m)).rounded()) * m
        return min(max(m, r), top)
    }

    /// Nearest `step × k + 1` (k ≥ 1), never above `max` (rounded down onto the grid).
    public static func snapFrames(_ n: Int, step s: Int, max: Int) -> Int {
        guard s > 0 else { return n }
        let k = Int((Double(n - 1) / Double(s)).rounded())
        let top = (max - 1) / s
        return Swift.max(1, Swift.min(k, top)) * s + 1
    }

    /// True when `spec` is a shape the runtime accepts for its model (antichat_video.protocol `shape_error`).
    public static func isValid(_ spec: VideoSpec, table: VideoPresetsTable = .bundled) -> Bool {
        let r = table.rule(spec.model)
        return spec.width % r.multiple == 0 && spec.height % r.multiple == 0 && (spec.frames - 1) % r.frameStep == 0
            && spec.width <= maxSide && spec.height <= maxSide && spec.frames <= maxFrames && spec.frames >= 5
    }

    // MARK: Estimate

    /// The speed-table preset the estimate (and `VideoHistory`) of `spec` is keyed on: same model and mode, the
    /// closest pixel count (nil = no measured row for this model).
    public static func basePreset(for spec: VideoSpec, speedClass: String,
                                  table: VideoSpeedTable = .bundled) -> VideoSpeedTable.Preset? {
        let px = Double(spec.width * spec.height)
        return table.presets(speedClass: speedClass)
            .filter { $0.model == spec.model && $0.mode == spec.mode.rawValue }
            .min { abs(log(Double($0.width * $0.height) / px)) < abs(log(Double($1.width * $1.height) / px)) }
    }

    /// The estimate of `spec` (VideoEstimator on the base row × history, then scaled):
    ///   t_step × (pixels ÷ base pixels) × (latent frames ÷ base latent frames), `spec.steps` steps,
    ///   decode × frames × (pixels ÷ base pixels), encode unchanged (text / image encoder).
    /// The default presets equal their measured rows (ratio 1). Memory verdict: the base row's.
    public static func estimate(_ spec: VideoSpec, speedClass: String, budgetGB: Double, residentGB: Double = 0,
                                history: [VideoHistory.Run] = [], table: VideoSpeedTable = .bundled) -> VideoEstimator.Estimate? {
        guard let base = basePreset(for: spec, speedClass: speedClass, table: table),
              let r = table.row(speedClass: speedClass, preset: base.key),
              var e = VideoEstimator.estimate(preset: base.key, speedClass: speedClass, budgetGB: budgetGB,
                                              residentGB: residentGB, history: history, table: table) else { return nil }
        let pixels = Double(spec.width * spec.height) / Double(max(1, base.width * base.height))
        let latent = Double((spec.frames - 1) / 4 + 1) / Double(max(1, (base.frames - 1) / 4 + 1))
        e.tStepS = r.tStepS * e.historyFactor * pixels * latent
        e.steps = spec.steps
        e.decodeS = Double(spec.frames) * r.decodeSPerFrame * pixels * e.historyFactor
        return e
    }
}
