// M3.T10 step 3 (R-052 AC3, R-282; NFR-V3; P-media-03 ported from speech-core `minInterruptionDuration`,
// `postPlaybackGuard`). Fed one Silero probability per 32 ms frame of the (echo-cancelled) input while the assistant
// speaks:
//   - the first voiced frame (P ≥ 0.5) outside the post-playback guard → `.candidate`: the output pauses in place, so
//     the assistant is silent within one frame of the onset (NFR-V3 ≤ 200 ms);
//   - ≥ `minInterruptionMs` (250 ms) of voiced frames → `.confirmed`: flush the output, cancel the generation
//     (≤ 300 ms after the onset), keep listening with the onset audio buffered (the new utterance is answered);
//   - the voice stops before that (a cough, a click: < 250 ms voiced, then ≥ `releaseMs` quiet) → `.falseAlarm`: the
//     output resumes where it paused, nothing is lost.
// Short gaps inside an onset (one quiet frame between syllables) do not reset the voiced count.
import Foundation

public struct BargeInDetector: Sendable {
    public struct Config: Sendable, Equatable {
        public var onset: Float = 0.5
        public var offset: Float = 0.35
        public var minInterruptionMs = 250
        /// Ignore onsets this soon after a chunk starts playing (the speaker's own attack can leak through AEC).
        public var postPlaybackGuardMs = 150
        /// Quiet time that ends a candidate without a barge-in.
        public var releaseMs = 160
        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        case none
        /// First voiced frame: pause the output. `onsetSample` = absolute input sample of the onset frame.
        case candidate(onsetSample: Int)
        case confirmed(onsetSample: Int)
        case falseAlarm
    }

    public let config: Config
    static let frameMs = 32

    private var onsetSample: Int?
    private var voicedMs = 0
    private var quietMs = 0
    private var guardUntilMs = 0
    private var clockMs = 0

    public init(config: Config = Config()) { self.config = config }

    public var isCandidate: Bool { onsetSample != nil }

    /// A TTS chunk started playing now: arms the post-playback guard.
    public mutating func chunkStarted() { guardUntilMs = clockMs + config.postPlaybackGuardMs }

    public mutating func reset() {
        onsetSample = nil
        voicedMs = 0
        quietMs = 0
    }

    /// One 32 ms frame ending at absolute input sample `endSample`.
    public mutating func feed(probability p: Float, endSample: Int) -> Decision {
        clockMs += Self.frameMs
        if let onset = onsetSample {
            if p >= config.offset {
                voicedMs += Self.frameMs
                quietMs = 0
                if voicedMs >= config.minInterruptionMs {
                    reset()
                    return .confirmed(onsetSample: onset)
                }
            } else {
                quietMs += Self.frameMs
                if quietMs >= config.releaseMs {
                    reset()
                    return .falseAlarm
                }
            }
            return .none
        }
        guard p >= config.onset, clockMs > guardUntilMs else { return .none }
        let onset = endSample - 512
        onsetSample = onset
        voicedMs = Self.frameMs
        quietMs = 0
        return .candidate(onsetSample: onset)
    }
}
