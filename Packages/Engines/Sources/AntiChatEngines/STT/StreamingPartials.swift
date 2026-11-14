// M3.T03 step 2 (R-050, NFR-V6 / NFR-V7): how a growing dictation buffer is recognised while recording.
// - Commits: once the open part (audio after the last commit) holds ≥ 6 s and a pause of ≥ 0.5 s (32 ms frames under
//   −45 dBFS) follows that, the open part up to the middle of the pause is recognised once and committed (its text
//   is final). With no pause the open part is cut at 30 s. So the final pass at stop only recognises the tail since
//   the last commit (NFR-V7 ≤ 0.4 s at T1 for a ≤ 30 s utterance), and no recognition run covers more than 30 s.
// - Partials for recognisers without a streaming model: every 500 ms the open part is re-recognised; partial =
//   committed text + its text (a run still busy when the next tick comes is not doubled).
import Foundation

public struct PartialWindow: Sendable, Equatable {
    public static let interval: Duration = .milliseconds(500)
    public static let sampleRate = 16_000
    public static let maxSeconds = 30
    public static let frame = 512  // 32 ms
    public static let quietDBFS: Float = -45
    public var minimumCommitSamples = 6 * PartialWindow.sampleRate
    public var pauseFrames = 16  // 0.51 s

    public enum Job: Sendable, Equatable {
        /// Recognise this range once and append it to the committed text.
        case commit(Range<Int>)
        /// Recognise this range; partial = committed text + its text.
        case partial(Range<Int>)
    }

    public private(set) var committedSamples = 0
    public private(set) var committedText = ""
    /// Buffer length at the last partial run (no new audio → no new run).
    public private(set) var lastPartialCount = 0
    /// Minimum new audio before the first partial (Parakeet pads short input; a run on 0.1 s is wasted work).
    public var minimumSamples = PartialWindow.sampleRate / 4
    /// One flag per complete 32 ms frame: below `quietDBFS`.
    public private(set) var quiet: [Bool] = []
    private var pending: [Float] = []

    public init() {}

    /// Feeds captured samples (frame energies for pause detection).
    public mutating func feed(_ samples: [Float]) {
        pending += samples
        while pending.count >= Self.frame {
            var ms: Float = 0
            for i in 0..<Self.frame { ms += pending[i] * pending[i] }
            ms /= Float(Self.frame)
            quiet.append(10 * log10(max(ms, 1e-12)) < Self.quietDBFS)
            pending.removeFirst(Self.frame)
        }
    }

    /// The next commit for a buffer of `count` samples: the open part up to the middle of the first pause after
    /// `minimumCommitSamples`, or its first 30 s when it is longer than that and has no pause.
    public func nextCommit(count: Int) -> Range<Int>? {
        let open = count - committedSamples
        guard open >= minimumCommitSamples else { return nil }
        var run = 0
        let first = (committedSamples + minimumCommitSamples) / Self.frame
        let last = min(quiet.count, count / Self.frame)
        if first < last {
            for f in first..<last {
                run = quiet[f] ? run + 1 : 0
                if run == pauseFrames {
                    let cut = (f - pauseFrames / 2) * Self.frame
                    return committedSamples..<cut
                }
            }
        }
        if open > Self.maxSeconds * Self.sampleRate {
            return committedSamples..<(committedSamples + Self.maxSeconds * Self.sampleRate)
        }
        return nil
    }

    /// The next partial run, or nil when there is nothing new.
    public mutating func nextPartial(count: Int) -> Range<Int>? {
        guard count > lastPartialCount, count - committedSamples >= minimumSamples else { return nil }
        lastPartialCount = count
        return committedSamples..<count
    }

    /// Commit first, else a partial (the re-run path's tick).
    public mutating func next(count: Int) -> Job? {
        if let c = nextCommit(count: count) { return .commit(c) }
        return nextPartial(count: count).map { .partial($0) }
    }

    public mutating func committed(_ range: Range<Int>, text: String) {
        guard range.lowerBound == committedSamples else { return }  // stale (a newer commit won)
        committedSamples = range.upperBound
        committedText = Self.join(committedText, text)
    }

    /// The partial shown for the open part's text.
    public func compose(_ open: String) -> String { Self.join(committedText, open) }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
