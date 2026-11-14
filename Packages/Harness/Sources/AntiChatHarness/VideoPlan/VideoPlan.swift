// M5.T09 step 2 (R-290 AC1, R-044, R-292; P-media-12): the plan card's content as a pure value, the API M5.T10 calls.
//   Input  = the rewritten prompt (the chat model's `create_video` call, as for images, M4.T07), the intent, the I2V
//            source image, Normal / Evil, this Mac (tier, speed class, B, what stays resident), the tier's video
//            models (catalog keys + capabilities), the call's length / shape / sound if it named them, local history.
//   Plan   = the resolved spec (VideoPresets), the estimate (VideoEstimator × VideoHistory), the Sound chip
//            (VideoSound: an `audio` model and a Normal chat), whether the chat would pause, and the offered presets.
//   Job    = what [Start] / the countdown hands to the queue (M5.T10/T11): prompt, mode, source image, spec, and the
//            history-free estimate + key that `VideoHistory` records after the run.
// Cancel writes no job: the card simply never produces one.
import Foundation

public struct VideoPlanInput: Sendable, Equatable {
    public var prompt: String
    public var intent: VideoPlanPolicy.Intent
    /// Set for image-to-video (Animate, an attached image).
    public var sourceImageID: String?
    public var isEvil: Bool
    public var tier: String
    public var speedClass: String
    public var budgetGB: Double
    /// What must stay loaded during the job (T3+: the chat model; T2: 0, chat is unloaded first).
    public var residentGB: Double
    /// The tier's video models (catalog order), e.g. vid-5b, vid-i2v, vid-ltx (`audio`).
    public var models: [VideoSound.Model]
    /// The `create_video` call's picks, if any (the card starts from them).
    public var length: VideoLength?
    public var shape: VideoShape?
    public var sound: Bool?
    public var history: [VideoHistory.Run]
    /// M5.T10 (lead decision): the speed-table presets `VideoEligibility` offers on this Mac (memory / tier). The card
    /// only resolves to a spec whose measured base preset is in it (a lower resolution, or Sound off, else not offered).
    /// nil = no restriction (tests, a model without measured rows keeps its spec and has no estimate).
    public var offeredPresets: [String]?

    public init(prompt: String, intent: VideoPlanPolicy.Intent, sourceImageID: String? = nil, isEvil: Bool = false,
                tier: String, speedClass: String, budgetGB: Double, residentGB: Double = 0, models: [VideoSound.Model],
                length: VideoLength? = nil, shape: VideoShape? = nil, sound: Bool? = nil, history: [VideoHistory.Run] = [],
                offeredPresets: [String]? = nil) {
        self.prompt = prompt; self.intent = intent; self.sourceImageID = sourceImageID; self.isEvil = isEvil
        self.tier = tier; self.speedClass = speedClass; self.budgetGB = budgetGB; self.residentGB = residentGB
        self.models = models; self.length = length; self.shape = shape; self.sound = sound; self.history = history
        self.offeredPresets = offeredPresets
    }

    public var mode: VideoMode { sourceImageID == nil ? .t2v : .i2v }
}

public struct VideoPlan: Sendable, Equatable {
    public var input: VideoPlanInput
    /// nil = video in this mode is not offered on this Mac (T0/T1, or I2V on T2-S1 "Shown-lite").
    public var spec: VideoSpec?
    public var estimate: VideoEstimator.Estimate?
    public var options: VideoPresetOptions?
    /// The Sound chip is shown (T2V, an `audio` model, Normal chat).
    public var soundChip: Bool
    public var chatWouldPause: Bool
    /// Advanced → exact length is set: the length presets are hidden (the exact length wins).
    public var exactLength: Bool
    /// The speed-table key the estimate and `VideoHistory` use (nil = no measured row for this model yet).
    public var historyKey: String?

    public var isOffered: Bool { spec != nil }

    /// - Parameters: `length` / `shape` / `sound` = the card's current picks (nil = the call's, else the tier default).
    public static func make(_ input: VideoPlanInput, length: VideoLength? = nil, shape: VideoShape? = nil, sound: Bool? = nil,
                            advanced: VideoAdvanced = .none, presets: VideoPresetsTable = .bundled,
                            speed: VideoSpeedTable = .bundled) -> VideoPlan {
        let plan = unfiltered(input, length: length, shape: shape, sound: sound, advanced: advanced, presets: presets, speed: speed)
        guard let offered = input.offeredPresets else { return plan }
        func within(_ p: VideoPlan) -> Bool { p.spec != nil && (p.historyKey.map(offered.contains) ?? true) }
        // The Sound chip shows only when a Sound-on clip is itself within the offer.
        func chipChecked(_ p: VideoPlan) -> VideoPlan {
            guard p.soundChip, p.spec?.sound != true else { return p }
            var q = p
            q.soundChip = within(firstOffered(input, sound: true))
            return q
        }
        func firstOffered(_ input: VideoPlanInput, sound: Bool?) -> VideoPlan {
            let base = unfiltered(input, length: length, shape: shape, sound: sound, advanced: advanced, presets: presets, speed: speed)
            if within(base) { return base }
            // A lower resolution of the same mode whose measured row fits (largest first).
            let allowed = presets.entry(tier: input.tier, speedClass: input.speedClass).map {
                input.mode == .t2v ? $0.resolutions : $0.i2vResolutions
            } ?? []
            for res in allowed.reversed() where res != base.spec?.resolution {
                var adv = advanced
                adv.resolution = res
                var p = unfiltered(input, length: length, shape: shape, sound: sound, advanced: adv, presets: presets, speed: speed)
                p.options?.resolution = res
                if within(p) { return p }
            }
            return base
        }
        let first = firstOffered(input, sound: sound)
        if within(first) { return chipChecked(first) }
        if first.spec?.sound == true {
            // Sound on is not within the offer here: the silent model, and no chip.
            var silent = firstOffered(input, sound: false)
            silent.soundChip = false
            if within(silent) { return silent }
        }
        var none = plan
        none.spec = nil; none.options = nil; none.estimate = nil; none.historyKey = nil; none.soundChip = false
        return none
    }

    static func unfiltered(_ input: VideoPlanInput, length: VideoLength?, shape: VideoShape?, sound: Bool?,
                           advanced: VideoAdvanced, presets: VideoPresetsTable, speed: VideoSpeedTable) -> VideoPlan {
        let mode = input.mode
        let chip = mode == .t2v && VideoSound.chipVisible(models: input.models, isEvil: input.isEvil)
        let soundOn = chip && (sound ?? input.sound ?? false)
        let model: String? = mode == .i2v
            ? input.models.first { $0.key.hasPrefix("vid-i2v") }?.key
            : VideoSound.model(for: soundOn, models: input.models.filter { !$0.key.hasPrefix("vid-i2v") }, isEvil: input.isEvil)?.key
        let options = VideoPresets.options(tier: input.tier, speedClass: input.speedClass, mode: mode, table: presets)
        var plan = VideoPlan(input: input, spec: nil, estimate: nil, options: options, soundChip: chip,
                             chatWouldPause: VideoPlanPolicy.chatWouldPause(tier: input.tier, verdict: nil),
                             exactLength: advanced.seconds > 0, historyKey: nil)
        guard let model, options != nil,
              let spec = VideoPresets.resolve(tier: input.tier, speedClass: input.speedClass, mode: mode, model: model,
                                              length: length ?? input.length, shape: shape ?? input.shape, sound: soundOn,
                                              advanced: advanced, table: presets) else {
            plan.options = nil
            return plan
        }
        plan.spec = spec
        plan.historyKey = VideoPresets.basePreset(for: spec, speedClass: input.speedClass, table: speed)?.key
        let history = plan.historyKey.map { k in input.history.filter { $0.presetKey == k } } ?? []
        plan.estimate = VideoPresets.estimate(spec, speedClass: input.speedClass, budgetGB: input.budgetGB,
                                              residentGB: input.residentGB, history: history, table: speed)
        plan.chatWouldPause = VideoPlanPolicy.chatWouldPause(tier: input.tier, verdict: plan.estimate?.verdict)
        return plan
    }

    /// R-290 AC2 / NFR-B2 / NFR-B4 for this plan.
    public func decision(power: VideoPlanPolicy.Power, lowPower: Bool) -> VideoPlanPolicy.Decision {
        VideoPlanPolicy.decide(intent: input.intent, power: power, lowPower: lowPower, estimateS: estimate?.seconds,
                               chatWouldPause: chatWouldPause)
    }

    /// The job [Start] / the countdown produces (nil when not offered).
    public var job: VideoPlanJob? {
        guard let spec else { return nil }
        let raw = estimate.map { $0.seconds / max($0.historyFactor, 1e-9) }
        return VideoPlanJob(prompt: input.prompt, mode: input.mode, sourceImageID: input.sourceImageID, spec: spec,
                            estimatedS: raw, historyKey: historyKey)
    }

    /// `video.plan` arguments: minutes (nil = no estimate → `video.plan.unknown`), resolution, seconds ("3", "3.4").
    public var planArgs: [String: String] {
        guard let spec else { return [:] }
        var a = ["resolution": spec.resolution, "seconds": Self.seconds(spec.seconds)]
        if let e = estimate { a["minutes"] = String(e.minutes) }
        return a
    }

    /// One decimal, without a trailing ".0".
    public static func seconds(_ s: Double) -> String {
        let r = (s * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

/// What [Start] (or the countdown) hands to the job queue. `estimatedS` is the estimate WITHOUT the history factor
/// (VideoHistory.Run.estimatedS), keyed by `historyKey`.
public struct VideoPlanJob: Sendable, Equatable {
    public var prompt: String
    public var mode: VideoMode
    public var sourceImageID: String?
    public var spec: VideoSpec
    public var estimatedS: Double?
    public var historyKey: String?
}
