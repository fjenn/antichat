// The turn state machine (M1.T06 step 1; architecture §6): idle → queued → loading → prefill → streaming →
// toolCall → finalizing → idle | interrupted | error. Transitions are a pure function of (phase, input) so the
// whole table is unit-tested (TurnStateTests); `TurnController` only applies them.
import AntiChatEngineProtocol
import Foundation

public enum TurnPhase: String, Sendable, Hashable, CaseIterable {
    /// No turn running (also the state after a turn that finished normally).
    case idle
    /// Accepted; the DB write / engine request is being set up.
    case queued
    /// The engine reported a model load in progress (`LifecycleEvent.loadState(.loading)`).
    case loading
    /// Prompt processing (`LifecycleEvent.prefillProgress`), no content yet.
    case prefill
    /// Text or reasoning deltas arriving.
    case streaming
    /// The model is emitting a tool call (the loop itself is M1.T16).
    case toolCall
    /// Terminal event received; the final DB write is running.
    case finalizing
    /// Ended by Stop, a crash or an engine failure after the turn started (partial text kept).
    case interrupted
    /// Ended by an engine failure before any content arrived.
    case error

    /// The turn is running: Stop is offered, Send is not.
    public var isActive: Bool {
        switch self {
        case .queued, .loading, .prefill, .streaming, .toolCall, .finalizing: true
        case .idle, .interrupted, .error: false
        }
    }

    public var isTerminal: Bool { !isActive }
}

/// What can happen to a turn.
public enum TurnInput: Sendable, Hashable {
    /// The user sent (or retried / edited): a new turn starts.
    case send
    case loadStarted
    case loadReady
    case prefillProgress
    /// A text or reasoning delta.
    case content
    case toolCallFragment
    case usage
    /// `done(reason)` from the engine.
    case done(FinishReason)
    /// `error(_)` from the engine (or the stream failed); `hadContent` = deltas were already shown.
    case failure(hadContent: Bool)
    /// The user pressed Stop.
    case stop
    /// The final write committed; the turn rests in the outcome's phase.
    case finalized(TurnState.Outcome)
}

public enum TurnState {
    /// The next phase, or nil when `input` is not valid in `phase` (ignored; e.g. a late token after Stop).
    public static func next(_ phase: TurnPhase, _ input: TurnInput) -> TurnPhase? {
        switch (phase, input) {
        // A new turn starts only from a resting state.
        case (.idle, .send), (.interrupted, .send), (.error, .send): return .queued
        case (_, .send): return nil

        // Stop: before any content (queued/loading/prefill) and while streaming or calling a tool, the turn is
        // interrupted at once; partial text (possibly empty) is kept (NFR-U6, IS-5).
        case (.queued, .stop), (.loading, .stop), (.prefill, .stop), (.streaming, .stop), (.toolCall, .stop):
            return .finalizing
        case (_, .stop): return nil

        case (.queued, .loadStarted), (.prefill, .loadStarted): return .loading
        case (.loading, .loadReady): return .prefill
        case (.queued, .loadReady): return .prefill
        case (.queued, .prefillProgress), (.loading, .prefillProgress), (.prefill, .prefillProgress): return .prefill

        case (.queued, .content), (.loading, .content), (.prefill, .content), (.streaming, .content),
            (.toolCall, .content):
            return .streaming
        case (.queued, .toolCallFragment), (.loading, .toolCallFragment), (.prefill, .toolCallFragment),
            (.streaming, .toolCallFragment), (.toolCall, .toolCallFragment):
            return .toolCall
        // Usage does not move the phase.
        case (let p, .usage) where p.isActive && p != .finalizing: return p

        case (let p, .done) where p.isActive && p != .finalizing: return .finalizing
        case (let p, .failure) where p.isActive && p != .finalizing: return .finalizing

        case (.finalizing, .finalized(let outcome)): return restingPhase(for: outcome)
        default: return nil
        }
    }

    /// The message status a turn ends with, from how it ended.
    public enum Outcome: Sendable, Hashable {
        case done
        case interrupted(errorCode: String?)
        case failed(errorCode: String)
    }

    /// End-of-turn classification: Stop or `done(cancelled)` → interrupted; an engine failure after content →
    /// interrupted with its code (R-004 AC3: the same notice after a crash or engine failure); a failure before
    /// any content → failed (ErrorInline on the message); any other `done` → done.
    public static func outcome(stopped: Bool, finish: FinishReason?, errorCode: String?, hadContent: Bool) -> Outcome {
        if let errorCode {
            return hadContent || stopped ? .interrupted(errorCode: errorCode) : .failed(errorCode: errorCode)
        }
        if stopped || finish == .cancelled { return .interrupted(errorCode: nil) }
        return .done
    }

    /// The phase shown after the final write.
    public static func restingPhase(for outcome: Outcome) -> TurnPhase {
        switch outcome {
        case .done: .idle
        case .interrupted: .interrupted
        case .failed: .error
        }
    }
}
