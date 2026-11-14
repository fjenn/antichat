// M5.T08 step 4 (R-046, G-046; P-media-12 design port of atomic-chat-core@6c7e9e8 `src/diffusion/video-eta.ts`,
// written from the description): the live ETA of a running video job.
//   remaining = estimate × (1 − progress) × (observed step time ÷ expected step time)
// `progress` is the share of the estimate already done (encode, then each finished denoise step, then decode).
// `slowdown` when the observed step time is more than 1.3 × the expected one; the UI shows it only through the
// thermal / yield messages (M5.T11), no extra copy.
import Foundation

public struct VideoETA: Sendable, Equatable {
    public static let slowdownRatio = 1.3

    public let estimate: VideoEstimator.Estimate
    public private(set) var stepsDone = 0
    private var denoiseStartedAt: TimeInterval?
    private var lastStepAt: TimeInterval?

    public init(estimate: VideoEstimator.Estimate) { self.estimate = estimate }

    /// The first denoise step begins (encode is done).
    public mutating func denoiseStarted(at t: TimeInterval) {
        denoiseStartedAt = t
    }

    /// Denoise step `step` (1-based) finished at `t` (seconds on any monotonic clock).
    public mutating func stepFinished(_ step: Int, at t: TimeInterval) {
        if denoiseStartedAt == nil { denoiseStartedAt = t - estimate.tStepS * Double(max(step, 1)) }
        stepsDone = min(max(step, stepsDone), estimate.steps)
        lastStepAt = t
    }

    /// Mean observed seconds per finished step (nil before the first step).
    public var observedStepS: Double? {
        guard let s = denoiseStartedAt, let l = lastStepAt, stepsDone > 0, l > s else { return nil }
        return (l - s) / Double(stepsDone)
    }

    /// Share of the estimate done: encode + finished steps (decode counts once every step is done).
    public var progress: Double {
        guard estimate.seconds > 0 else { return 0 }
        var done = denoiseStartedAt != nil ? estimate.encodeS : 0
        done += Double(stepsDone) * estimate.tStepS
        return min(1, done / estimate.seconds)
    }

    public var remainingS: Double {
        Self.remaining(estimateS: estimate.seconds, progress: progress, observedStepS: observedStepS, expectedStepS: estimate.tStepS)
    }

    public var slowdown: Bool { Self.isSlowdown(observedStepS: observedStepS, expectedStepS: estimate.tStepS) }

    /// The pure rule (testable without a clock).
    public static func remaining(estimateS: Double, progress: Double, observedStepS: Double?, expectedStepS: Double) -> Double {
        let base = max(0, estimateS * (1 - min(max(progress, 0), 1)))
        guard let o = observedStepS, o > 0, expectedStepS > 0 else { return base }
        return base * (o / expectedStepS)
    }

    public static func isSlowdown(observedStepS: Double?, expectedStepS: Double) -> Bool {
        guard let o = observedStepS, expectedStepS > 0 else { return false }
        return o > slowdownRatio * expectedStepS
    }
}
