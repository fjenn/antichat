// What the pending assistant message shows before text arrives (M1.T06 step 3; IS-2, NFR-U3, NFR-U4):
// the PendingDot at once; "Loading model…" while the engine reports a load (≤ 2 s, NFR-U3 — shown as soon as
// the load is reported); otherwise, after 2.5 s without text, a status verb (`status.verb.1…4`), advancing
// every 4 s and staying on the last. No seconds counter for plain replies (counters are for tool/image/video
// jobs). Pure, so the view recomputes it from a timeline.
import Foundation

public enum StatusLine: Sendable, Hashable {
    /// Nothing (content is streaming, or the turn is over).
    case hidden
    /// The PendingDot alone.
    case pendingDot
    /// `status.loadingModel`.
    case loadingModel
    /// `status.verb.<n>`, n in 1…4.
    case verb(Int)
    /// `status.thinking`: a synchronous compaction runs before the request (M1.T18 step 4).
    case thinking
    /// M6.T02 step 7: `status.summarising` with the map-reduce driver's real progress.
    case summarising(MapReduceSummariser.Progress)
    /// M6.T02 step 6 (NFR-C5): `status.reading` with the real prefill percent of a whole document.
    case reading(file: String, percent: Int)

    /// The copy-deck key of the label, if any.
    public var copyKey: String? {
        switch self {
        case .hidden, .pendingDot: nil
        case .loadingModel: "status.loadingModel"
        case .verb(let n): "status.verb.\(n)"
        case .thinking: "status.thinking"
        case .summarising: "status.summarising"
        case .reading: "status.reading"
        }
    }

    /// The label's placeholders.
    public var copyArgs: [String: String] {
        switch self {
        case .summarising(let p): return ["n": "\(p.n)", "total": "\(p.total)", "percent": "\(p.percent)"]
        case .reading(let file, let percent): return ["file": file, "percent": "\(percent)"]
        default: return [:]
        }
    }

    /// The dot is shown with every pre-content state.
    public var showsDot: Bool { self != .hidden }
}

public struct StatusLineModel: Sendable, Hashable {
    /// NFR-U4: the verb appears after 2.5 s without text (`motion.statusVerb.delay`).
    public static let verbDelay: Duration = .milliseconds(2500)
    /// How long each verb stays before the next one.
    public static let verbStep: Duration = .seconds(4)
    public static let verbCount = 4

    public var phase: TurnPhase
    public var hasContent: Bool
    /// The engine reported `loadState(.loading)` and not yet `.ready`.
    public var modelLoading: Bool
    /// M1.T18: the older turns are being summarised before the request.
    public var compacting: Bool
    /// M6.T02 step 7: the whole-document summary's progress (nil = not summarising).
    public var summarising: MapReduceSummariser.Progress?
    /// M6.T02 step 6: the whole document being prefilled and the real percent (nil = no document prefill reported).
    public var reading: Reading?
    public struct Reading: Sendable, Hashable {
        public var file: String
        public var percent: Int
        public init(file: String, percent: Int) { self.file = file; self.percent = percent }
    }

    public init(phase: TurnPhase, hasContent: Bool, modelLoading: Bool, compacting: Bool = false,
                summarising: MapReduceSummariser.Progress? = nil, reading: Reading? = nil) {
        self.compacting = compacting
        self.summarising = summarising
        self.reading = reading
        self.phase = phase
        self.hasContent = hasContent
        self.modelLoading = modelLoading
    }

    /// The status `elapsed` after the send.
    public func status(elapsed: Duration) -> StatusLine {
        guard phase.isActive, phase != .finalizing, !hasContent else { return .hidden }
        if modelLoading || phase == .loading { return .loadingModel }
        if compacting { return .thinking }
        if let summarising { return .summarising(summarising) }
        if phase == .prefill, let reading { return .reading(file: reading.file, percent: reading.percent) }
        guard elapsed >= Self.verbDelay else { return .pendingDot }
        let steps = Int((elapsed - Self.verbDelay) / Self.verbStep)
        return .verb(min(Self.verbCount, steps + 1))
    }

    /// The next instant (as elapsed time) at which `status` changes, for the view's timeline (nil = never).
    public func nextChange(after elapsed: Duration) -> Duration? {
        guard phase.isActive, phase != .finalizing, !hasContent, !modelLoading, phase != .loading, !compacting,
              summarising == nil, !(phase == .prefill && reading != nil)
        else { return nil }
        if elapsed < Self.verbDelay { return Self.verbDelay }
        let steps = Int((elapsed - Self.verbDelay) / Self.verbStep)
        guard steps + 1 < Self.verbCount else { return nil }
        return Self.verbDelay + Self.verbStep * (steps + 1)
    }
}
