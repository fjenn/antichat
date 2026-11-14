// M5.T09 steps 3–4 (R-290 AC2, NFR-B2 / NFR-B4 video parts; P-media-12): when the plan card starts by itself.
//   Auto-start after a visible 10 s countdown (`video.countdown`) **iff** the intent is explicit (Create video chip,
//   Animate button, or a request naming a video/clip/animation as classified by the router) AND the Mac is on AC
//   power AND Low Power Mode is off AND the estimate is ≤ 5 min AND the chat would not be paused (T2 unloads chat).
//   Otherwise the card waits for [Start]. An unknown estimate is never ≤ 5 min.
//   Ask first: battery < 20 % and not charging → `video.battery` ("You're on battery ({percent}%). Start anyway?",
//   [Start] [Later]); Low Power Mode → `video.lowPower` (same buttons). When both hold, the battery ask is shown (it
//   carries the more urgent fact); neither ask ever auto-starts.
// Pure: the UI maps Platform's `PowerSource` (IOPSCopyPowerSourcesInfo, or `-FakePower ac|battery:<pct>|lowpower`)
// into `Power`.
import Foundation

public enum VideoPlanPolicy {
    public static let countdownSeconds = 10
    /// R-290 AC2: "the estimate is ≤ 5 min".
    public static let autoStartMaxSeconds: Double = 5 * 60
    /// NFR-B4 (video part): below this on battery the card asks before starting.
    public static let batteryAskBelowPercent = 20

    /// How the user asked for the video.
    public enum Intent: String, Sendable, Equatable, CaseIterable {
        /// `+ → Create video` chip in the composer.
        case createVideoChip
        /// Animate on an image card or attachment.
        case animate
        /// A request naming a video / clip / animation (router `video_create` / `video_from_image`).
        case namedVideo
        /// The router inferred video without the user naming it.
        case inferred

        public var isExplicit: Bool { self != .inferred }
    }

    public enum Power: Sendable, Equatable {
        case ac
        /// On battery, not charging. `percent` nil = unknown.
        case battery(percent: Int?)

        public var onAC: Bool { self == .ac }
    }

    public enum Ask: Sendable, Equatable {
        /// `video.battery` / `battery.ask`.
        case battery(percent: Int)
        /// `video.lowPower`.
        case lowPower

        public var copyKey: String {
            switch self {
            case .battery: "video.battery"
            case .lowPower: "video.lowPower"
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Visible countdown, then the job starts unless [Change] / [Cancel] is clicked.
        case countdown(seconds: Int)
        /// Wait for [Start]; `ask` = the sentence shown above the buttons first.
        case waitForStart(ask: Ask?)
    }

    /// R-290 AC2, exactly.
    public static func shouldAutoStart(intent: Intent, power: Power, lowPower: Bool, estimateS: Double?,
                                       chatWouldPause: Bool) -> Bool {
        guard let s = estimateS else { return false }
        return intent.isExplicit && power.onAC && !lowPower && s <= autoStartMaxSeconds && !chatWouldPause
    }

    /// NFR-B4 / NFR-B2 (video parts): the ask the card shows before it may start.
    public static func ask(power: Power, lowPower: Bool) -> Ask? {
        if case .battery(let p?) = power, p < batteryAskBelowPercent { return .battery(percent: p) }
        return lowPower ? .lowPower : nil
    }

    public static func decide(intent: Intent, power: Power, lowPower: Bool, estimateS: Double?,
                              chatWouldPause: Bool) -> Decision {
        if let a = ask(power: power, lowPower: lowPower) { return .waitForStart(ask: a) }
        return shouldAutoStart(intent: intent, power: power, lowPower: lowPower, estimateS: estimateS,
                               chatWouldPause: chatWouldPause) ? .countdown(seconds: countdownSeconds) : .waitForStart(ask: nil)
    }

    /// Would the job pause the chat? T0–T2: the chat model steps aside for video (cross-task contract 2); T3+: only
    /// when chat + video do not fit B together (`exceeds` with the chat resident).
    public static func chatWouldPause(tier: String, verdict: VideoEstimator.MemoryVerdict?) -> Bool {
        ["T0", "T1", "T2"].contains(tier) || verdict == .exceeds
    }
}
