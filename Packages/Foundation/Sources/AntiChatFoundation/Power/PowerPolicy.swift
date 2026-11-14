// M2.T14 (R-207, R-206 AC3/AC8, NFR-M2, NFR-B2, NFR-B3, NFR-M4): the power / thermal / pressure decisions, pure and
// shared — the app computes them (Settings › General › Performance, PowerSource, thermal state) and sends the result in
// `SetPolicy`; the helper applies it (keep-alive, media step-down, job pacing). They live in AntiChatFoundation, not
// AntiChatEngines: the app never links the engines and Platform may not import EngineProtocol (A-M2-T14a).
import Foundation

/// `set.performance` (Settings › General): Auto (default) / Maximum / Battery saver.
public enum PerformanceMode: String, Codable, Sendable, CaseIterable { case auto, maximum, batterySaver }

/// Memory pressure as the scheduler sees it (DispatchSource memory pressure, `kern.memorystatus_level`).
public enum PressureLevel: Int, Sendable, Comparable, Codable {
    case normal, warning, critical
    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
    public init?(name: String) {
        switch name {
        case "warn", "warning": self = .warning
        case "critical": self = .critical
        case "normal": self = .normal
        default: return nil
        }
    }
}

public enum PowerPolicy {
    /// Auto switches to Battery saver below this battery level (on battery) or in Low Power Mode (R-207 AC1).
    public static let autoSaverBelowPercent = 20
    /// Battery saver keep-alive (NFR-M2: 5 min on battery / Low Power).
    public static let saverKeepAliveSeconds = 300
    /// Renderer reveal cadence in Low Power Mode (the renderer runs at 40 Hz otherwise, `MessageMarkdownView.cadence`).
    public static let saverRenderHz = 30

    /// The mode in effect. `enabled` = FeatureFlag.powerPolicy (off → Maximum: no automatic change).
    public static func effective(_ mode: PerformanceMode, onAC: Bool, batteryPercent: Int?, lowPowerMode: Bool,
                                 enabled: Bool = true) -> PerformanceMode {
        guard enabled else { return .maximum }
        switch mode {
        case .maximum: return .maximum
        case .batterySaver: return .batterySaver
        case .auto:
            if lowPowerMode { return .batterySaver }
            if !onAC, (batteryPercent ?? 100) < autoSaverBelowPercent { return .batterySaver }
            return .maximum
        }
    }

    /// Battery saver effects (R-207 AC2): keep-alive 5 min, image / video defaults one step lower (NFR-B2; applied by
    /// the media engines in M4/M5), render cadence 30 Hz.
    public struct Effects: Sendable, Equatable {
        public var lowPower: Bool
        public var mediaStepDown: Bool
        public var renderHz: Int
    }

    public static func effects(_ effective: PerformanceMode) -> Effects {
        effective == .batterySaver ? Effects(lowPower: true, mediaStepDown: true, renderHz: saverRenderHz)
            : Effects(lowPower: false, mediaStepDown: false, renderHz: 60)
    }
}

/// `ProcessInfo.thermalState` (NFR-B3): `.serious` → heavy jobs sleep between steps (≤ 30 % throughput loss) + the
/// `power.cooler` notice; `.critical` → video pauses with [Resume]; chat always continues; never a silent change.
public enum ThermalPolicy {
    public enum State: String, Codable, Sendable { case nominal, fair, serious, critical }

    /// Pause after each heavy-job step, as a fraction of the step's own time: 0.25 → throughput × 0.8 (20 % loss).
    public static let seriousPauseFraction = 0.25

    public static func pauseAfterStep(_ stepSeconds: Double, _ s: State) -> Double {
        s == .serious || s == .critical ? stepSeconds * seriousPauseFraction : 0
    }

    /// Throughput relative to nominal under `s` (NFR-B3 bar: ≥ 0.7 at serious).
    public static func throughput(_ s: State) -> Double { 1 / (1 + pauseAfterStep(1, s)) }

    public static func pausesVideo(_ s: State) -> Bool { s == .critical }

    /// The one-line notice for a state change (nil = none; "never silently degrade").
    public static func notice(_ s: State) -> String? {
        switch s {
        case .serious: "power.cooler"
        case .critical: "power.cooler"
        default: nil
        }
    }

    // MARK: M5.T11 — the running video job (NFR-B3)

    /// What a running video job does under `s`: run; pace (a fixed sleep at every step boundary: `/pause` + `/resume`
    /// for the FastMetal runtime, SIGSTOP / SIGCONT between progress polls for sd-server); or pause until the state
    /// drops (or the user presses [Resume]).
    public enum VideoAction: Sendable, Equatable {
        case run
        case paceSteps(seconds: Double)
        case pause
    }

    /// The fixed between-step sleep of a video job at `.serious` (M5.md T11 step 5).
    public static let videoSeriousStepPause = 2.0

    public static func videoAction(_ s: State) -> VideoAction {
        switch s {
        case .critical: .pause
        case .serious: .paceSteps(seconds: videoSeriousStepPause)
        default: .run
        }
    }

    /// The video job card's line for `s` (nil = none): `.serious` "Running slower…", `.critical` "Paused — hot".
    public static func videoNotice(_ s: State) -> String? {
        switch s {
        case .serious: "thermal.serious"
        case .critical: "video.paused.hot"
        default: nil
        }
    }

    /// Throughput of a whole video job paced at `.serious` relative to nominal: `steps` boundaries each add the fixed
    /// pause to a job of `jobSeconds` (NFR-B3 bar ≥ 0.7). The step count is small (3 DMD steps for vid-5b, 20 for
    /// sd.cpp I2V) against minute-long jobs, so the loss stays well under 30 % on every measured preset.
    public static func videoThroughput(jobSeconds: Double, steps: Int, _ s: State) -> Double {
        guard jobSeconds > 0 else { return 1 }
        guard case .paceSteps(let p) = videoAction(s) else { return s == .critical ? 0 : 1 }
        return jobSeconds / (jobSeconds + Double(steps) * p)
    }
}
