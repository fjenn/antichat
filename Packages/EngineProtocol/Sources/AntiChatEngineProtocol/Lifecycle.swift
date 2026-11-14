// Lifecycle requests and the non-content event stream (architecture.md §4.2–§4.3; M1.T05 step 1):
// Warmup (lazy, first composer focus), Evict, SetPolicy; LifecycleEvent = load state / load progress /
// prefill progress, kept off the seven-event adapter contract.
import AntiChatFoundation
import Foundation

public enum LoadState: String, Codable, Sendable, Hashable { case loading, ready, evicted }

public enum LifecycleEvent: Codable, Sendable, Hashable {
    case loadState(LoadState)
    /// 0…1 while loading (ScriptedEngine `load` steps; real engines report only state).
    case loadProgress(Double)
    /// 0…1 of the uncached prompt (feeds NFR-C5 in M1.T26).
    case prefillProgress(Double)
    /// AT-273 (round 65): liveness while the model generates and nothing visible streams — the tokens of a tool call
    /// (mlx-swift-lm hands a call over only once it is complete, so a long `create_document` / `create_spreadsheet`
    /// call was minutes of silence to the turn's stall watchdog). `tokens` = generated so far in this request. Sent at
    /// most about once a second and only while no content event went out in that time; carries no content.
    case generating(tokens: Int)
    /// M2.T13 (NFR-R5): the requested model did not fit, the scheduler loaded the lighter `to` (`model.usingLighter`).
    case usingLighter(from: String, to: String)
}

public struct Warmup: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var modelSlot: ModelSlot
    /// M2.T12: which pack × mode the warm-up is for (`chat` / `normal`); nil = chat, Normal.
    public var pack: String?
    public var mode: String?
    /// M2.T15 (R-206 AC5): a hover hint (ModeSwitch, ⇧⌘E key-down, mic) — `.utility`, cancelled by a newer hint,
    /// never evicts a leased model. nil / false = the M1 lazy warm-up on first composer focus.
    public var predictive: Bool?
    public init(requestID: UUID = UUID(), modelSlot: ModelSlot, pack: String? = nil, mode: String? = nil, predictive: Bool? = nil) {
        self.requestID = requestID
        self.modelSlot = modelSlot
        self.pack = pack
        self.mode = mode
        self.predictive = predictive
    }
}

public struct Evict: Codable, Sendable, Hashable {
    public var requestID: UUID
    /// nil evicts everything resident.
    public var key: String?
    public init(requestID: UUID = UUID(), key: String? = nil) {
        self.requestID = requestID
        self.key = key
    }
}

public struct SetPolicy: Codable, Sendable, Hashable {
    /// Budget B in bytes (hardware-tiers §2.2; M0.md C5 tier cap). 0 = no cap.
    public var budgetB: UInt64
    /// Chat keep-alive after last use (Advanced `set.cap.keepLoaded`: 300 / 900 / 1800; ≤ 0 = Never; NFR-M2).
    public var keepAliveSeconds: Int
    public var lowPower: Bool
    /// DeltaBatcher window (16 ms / 8 tokens; fallback 33 ms / 16 tokens).
    public var batch: BatchPolicy
    /// M2.T12: "Allow loads above the memory budget" (NFR-R5, Advanced).
    public var allowOverBudget: Bool
    /// M2.T12: the app is frontmost with a chat open — chat models are not unloaded (NFR-M2).
    public var frontmostChatOpen: Bool
    /// M2.T12: T0–T2 — image / video / csam models are never resident without a job (NFR-R4).
    public var lowTier: Bool
    /// Debug: the scheduler's keep-alive clock runs this many times faster (AT-NFR-M2 scaled run).
    public var testClockScale: Double?
    /// M2.T14: Battery saver in effect — image / video defaults one step lower (NFR-B2; applied by M4/M5 engines).
    public var mediaStepDown: Bool
    /// M2.T14: `ProcessInfo.thermalState` of the app (NFR-B3 job pacing; nil = nominal).
    public var thermal: ThermalPolicy.State?
    /// Debug (`-FakePressure warn|critical`): the helper's PressureMonitor handles this level as if the OS sent it.
    public var testPressure: String?
    /// M2.T15 (E.2.7 "warm if fits", NFR-C7): T3+ and `FeatureFlag.warmSecondVariant` on — the other mode's chat
    /// model stays loaded beside the current one when both fit B (MLX holds two containers). false → the other chat
    /// model always unloads first (unload → load). nil (benches, older senders) → the plain E.2.7 budget plan.
    public var warmSecondVariant: Bool?

    public init(budgetB: UInt64, keepAliveSeconds: Int = 900, lowPower: Bool = false, batch: BatchPolicy = .standard,
                allowOverBudget: Bool = false, frontmostChatOpen: Bool = false, lowTier: Bool = true, testClockScale: Double? = nil,
                mediaStepDown: Bool = false, thermal: ThermalPolicy.State? = nil, testPressure: String? = nil,
                warmSecondVariant: Bool? = nil) {
        self.warmSecondVariant = warmSecondVariant
        self.mediaStepDown = mediaStepDown
        self.thermal = thermal
        self.testPressure = testPressure
        self.budgetB = budgetB
        self.keepAliveSeconds = keepAliveSeconds
        self.lowPower = lowPower
        self.batch = batch
        self.allowOverBudget = allowOverBudget
        self.frontmostChatOpen = frontmostChatOpen
        self.lowTier = lowTier
        self.testClockScale = testClockScale
    }

    enum CodingKeys: String, CodingKey {
        case budgetB, keepAliveSeconds, lowPower, batch, allowOverBudget, frontmostChatOpen, lowTier, testClockScale
        case mediaStepDown, thermal, testPressure, warmSecondVariant
    }

    /// Older senders omit the M2 fields (decoded as their defaults).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        budgetB = try c.decode(UInt64.self, forKey: .budgetB)
        keepAliveSeconds = try c.decodeIfPresent(Int.self, forKey: .keepAliveSeconds) ?? 900
        lowPower = try c.decodeIfPresent(Bool.self, forKey: .lowPower) ?? false
        batch = try c.decodeIfPresent(BatchPolicy.self, forKey: .batch) ?? .standard
        allowOverBudget = try c.decodeIfPresent(Bool.self, forKey: .allowOverBudget) ?? false
        frontmostChatOpen = try c.decodeIfPresent(Bool.self, forKey: .frontmostChatOpen) ?? false
        lowTier = try c.decodeIfPresent(Bool.self, forKey: .lowTier) ?? true
        testClockScale = try c.decodeIfPresent(Double.self, forKey: .testClockScale)
        mediaStepDown = try c.decodeIfPresent(Bool.self, forKey: .mediaStepDown) ?? false
        thermal = try c.decodeIfPresent(ThermalPolicy.State.self, forKey: .thermal)
        testPressure = try c.decodeIfPresent(String.self, forKey: .testPressure)
        warmSecondVariant = try c.decodeIfPresent(Bool.self, forKey: .warmSecondVariant)
    }
}
