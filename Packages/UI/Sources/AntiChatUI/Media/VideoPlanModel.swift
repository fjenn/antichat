// M5.T09 (R-290 AC1–AC3, R-044, NFR-B2 / NFR-B4 video parts; P-media-12): the plan card's view-model — the API M5.T10
// calls once the video route has the chat model's rewritten prompt:
//   VideoPlanModel(input: VideoPlanInput(prompt:intent:sourceImageID:isEvil:tier:speedClass:budgetGB:residentGB:models:…),
//                  onStart: { job in queue it (M5.T11) }, onCancel: { remove the card })
// It decides once, on creation, between the 10 s countdown and waiting for [Start] (VideoPlanPolicy), ticks the
// countdown each second (`tick()`, driven by the card; tests call it directly), and stops it for good on any click on
// [Change] or [Cancel]. [Change] opens the inline picker; every pick re-plans and re-estimates. [Cancel] / [Later]
// remove the card and write no job: `onStart` is the only way a job comes out of it.
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import Defaults
import Foundation
import Observation

@MainActor @Observable
public final class VideoPlanModel {
    public enum Phase: Sendable, Equatable {
        /// Waits for [Start]; `ask` = the battery / Low Power sentence shown first.
        case waiting(ask: VideoPlanPolicy.Ask?)
        /// "Starting in {n}…", one tick per second.
        case countdown(remaining: Int)
        /// The job was handed over (the host replaces the card with the VideoJobCard, M5.T11).
        case started
        /// Cancel / Later: the card is gone, no job.
        case cancelled
    }

    public let input: VideoPlanInput
    public let advanced: VideoAdvanced
    public private(set) var plan: VideoPlan
    public private(set) var phase: Phase
    /// [Change] opened the inline picker.
    public private(set) var editing = false
    public private(set) var length: VideoLength?
    public private(set) var shape: VideoShape?
    public private(set) var sound: Bool
    @ObservationIgnored private let presets: VideoPresetsTable
    @ObservationIgnored private let speed: VideoSpeedTable
    @ObservationIgnored private let onStart: (VideoPlanJob) -> Void
    @ObservationIgnored private let onCancel: () -> Void

    public init(input: VideoPlanInput, power: VideoPlanPolicy.Power, lowPower: Bool, advanced: VideoAdvanced = .none,
                presets: VideoPresetsTable = .bundled, speed: VideoSpeedTable = .bundled,
                onStart: @escaping (VideoPlanJob) -> Void = { _ in }, onCancel: @escaping () -> Void = {}) {
        self.input = input
        self.advanced = advanced
        self.presets = presets
        self.speed = speed
        self.onStart = onStart
        self.onCancel = onCancel
        let plan = VideoPlan.make(input, advanced: advanced, presets: presets, speed: speed)
        self.plan = plan
        length = plan.spec?.length
        shape = plan.spec?.shape
        sound = plan.spec?.sound ?? false
        switch plan.isOffered ? plan.decision(power: power, lowPower: lowPower) : .waitForStart(ask: nil) {
        case .countdown(let s): phase = .countdown(remaining: s)
        case .waitForStart(let ask): phase = .waiting(ask: ask)
        }
    }

    /// The live Mac: power from IOPSCopyPowerSourcesInfo (or `-FakePower`), Advanced → Video from Settings.
    public convenience init(input: VideoPlanInput, onStart: @escaping (VideoPlanJob) -> Void = { _ in },
                            onCancel: @escaping () -> Void = {}) {
        let p = PowerSource.current()
        self.init(input: input, power: VideoPlanPolicy.Power(p), lowPower: p.lowPowerMode, advanced: .current,
                  onStart: onStart, onCancel: onCancel)
    }

    public var isCountingDown: Bool { if case .countdown = phase { true } else { false } }
    public var isVisible: Bool { phase != .cancelled && phase != .started }
    public var ask: VideoPlanPolicy.Ask? { if case .waiting(let a) = phase { a } else { nil } }

    /// One second of the countdown; at 0 the job starts.
    public func tick() {
        guard case .countdown(let n) = phase else { return }
        if n <= 1 { start() } else { phase = .countdown(remaining: n - 1) }
    }

    /// [Start] (or the end of the countdown): hands the job over once.
    public func start() {
        guard isVisible, let job = plan.job else { return }
        phase = .started
        editing = false
        onStart(job)
    }

    /// [Change]: stops the countdown for good and toggles the inline picker.
    public func change() {
        guard isVisible else { return }
        stopCountdown()
        editing.toggle()
    }

    /// [Cancel] / [Later]: removes the card; no job is written.
    public func cancel() {
        guard isVisible else { return }
        phase = .cancelled
        editing = false
        onCancel()
    }

    public func pick(length: VideoLength) { self.length = length; replan() }
    public func pick(shape: VideoShape) { self.shape = shape; replan() }
    public func pick(sound: Bool) { self.sound = sound; replan() }

    private func stopCountdown() {
        if isCountingDown { phase = .waiting(ask: nil) }
    }

    private func replan() {
        stopCountdown()
        plan = VideoPlan.make(input, length: length, shape: shape, sound: sound, advanced: advanced, presets: presets, speed: speed)
    }

    // MARK: Copy

    /// `video.plan` "About {minutes} min on this Mac · {resolution} · {seconds} s", or `video.plan.unknown` when the
    /// model has no measured speed row yet.
    public var planText: CopyText {
        CopyText(CopyKey(plan.estimate == nil ? "video.plan.unknown" : "video.plan"), plan.planArgs)
    }

    public var askText: CopyText? {
        switch ask {
        case .battery(let p): CopyText(CopyKey("video.battery"), ["percent": String(p)])
        case .lowPower: CopyText(CopyKey("video.lowPower"))
        case nil: nil
        }
    }

    public var countdownText: CopyText? {
        if case .countdown(let n) = phase { return CopyText(CopyKey("video.countdown"), ["n": String(n)]) }
        return nil
    }
}

extension VideoPlanPolicy.Power {
    /// Platform's power source: charging (AC) or on battery with its percentage.
    public init(_ p: PowerSource) {
        self = p.onAC ? .ac : .battery(percent: p.batteryPercent)
    }
}

extension VideoAdvanced {
    /// Settings → Capabilities → Advanced → Video.
    public static var current: VideoAdvanced {
        VideoAdvanced(steps: Defaults[.videoAdvancedSteps], resolution: Defaults[.videoAdvancedResolution],
                      seconds: Defaults[.videoAdvancedSeconds])
    }
}

extension VideoSound.Model {
    /// The tier's video models (catalog order) with their capabilities, for `VideoPlanInput.models`. Evil video uses
    /// the Normal media models (Q-009 a); VideoSound hides the Sound chip in Evil chats.
    public static func tierModels(selection: Selection, catalog: ModelCatalog) -> [VideoSound.Model] {
        guard let slot = selection.slot(.video, .normal) else { return [] }
        let ids = slot.installIDs.isEmpty ? [slot.modelID].compactMap { $0 } : slot.installIDs
        return ids.compactMap { id in
            guard let m = catalog.models[id], m.role == "video" else { return nil }
            return VideoSound.Model(key: id, capabilities: m.capabilities)
        }
    }
}

extension VideoPlanInput {
    /// This Mac's facts from the hardware profile (+ catalog for the T3+ resident chat model, as VideoEligibility).
    public init(prompt: String, intent: VideoPlanPolicy.Intent, sourceImageID: String? = nil, isEvil: Bool,
                profile: HardwareProfile, selection: Selection, catalog: ModelCatalog, length: VideoLength? = nil,
                shape: VideoShape? = nil, sound: Bool? = nil, history: [VideoHistory.Run] = []) {
        let e = VideoEligibility.Input(profile: profile, selection: selection, catalog: catalog)
        // M5.T10 (lead decision): the card offers only presets within the eligibility offer (memory / tier).
        let offered: [String] = if case .eligible(let o) = VideoEligibility.evaluate(e) { o.presets } else { [] }
        self.init(prompt: prompt, intent: intent, sourceImageID: sourceImageID, isEvil: isEvil, tier: e.tier,
                  speedClass: e.speedClass, budgetGB: e.budgetGB, residentGB: e.residentGB,
                  models: VideoSound.Model.tierModels(selection: selection, catalog: catalog),
                  length: length, shape: shape, sound: sound, history: history, offeredPresets: offered)
    }
}
