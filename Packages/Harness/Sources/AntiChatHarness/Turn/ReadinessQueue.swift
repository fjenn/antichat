// Type before the model is ready (M1.T19 step 7, R-299, NFR-U3, IS-2): a send while the chat model is downloading
// (M2) or loading (`LifecycleEvent.loadState(.loading)` + `loadProgress`, reported by the warmup the first typed
// character starts) is accepted at once (bubble + pending dot + Stop, NFR-U2) but held: the user bubble reads
// "Sending when Chat is ready (NN%)" (`composer.queuedPct`, NN = load or download %) with a cancel ×, the reply area
// shows `status.loadingModel`, and nothing reaches the engine until `.ready`, when the held turns go out in order
// (≤ 200 ms). Cancelling before that removes the turn and sends nothing.
//
// Pure value type over the readiness events; the window (ChatSessions) owns one and feeds it the warmup's
// lifecycle events and, from M2, the download manager's progress (`downloadEvents`).
import AntiChatEngineProtocol
import Foundation

/// Whether the chat model can take a request now.
public enum ChatReadiness: Sendable, Hashable {
    /// Nothing reported (no warmup yet, or the model was evicted): sends go straight out; a load inside the
    /// request still shows `status.loadingModel` (NFR-U3).
    case unknown
    /// The model is loading; `progress` 0…1 once the engine reports it.
    case loading(progress: Double?)
    /// The model is downloading (M2's download manager); `progress` 0…1.
    case downloading(progress: Double)
    case ready
    /// The warmup failed: sends go out and the request reports the error (ErrorInline).
    case failed

    /// A send goes to the engine now (otherwise it is held).
    public var acceptsRequests: Bool {
        switch self {
        case .unknown, .ready, .failed: true
        case .loading, .downloading: false
        }
    }

    /// NN of "Sending when Chat is ready (NN%)", nil before any progress is known.
    public var percent: Int? {
        switch self {
        case .loading(let p?), .downloading(let p): Int((min(1, max(0, p)) * 100).rounded(.down))
        default: nil
        }
    }
}

/// What can change readiness.
public enum ReadinessEvent: Sendable, Hashable {
    case lifecycle(LifecycleEvent)
    case downloadProgress(Double)
    case downloadFinished
    /// The warmup call returned (`failed` = it returned an error).
    case warmupFinished(failed: Bool)
}

public struct ReadinessQueue<Item: Hashable & Sendable>: Sendable {
    public private(set) var readiness: ChatReadiness
    /// Held sends, oldest first.
    public private(set) var held: [Item] = []

    public init(readiness: ChatReadiness = .unknown) { self.readiness = readiness }

    /// The readiness after `event`.
    public static func next(_ r: ChatReadiness, _ event: ReadinessEvent) -> ChatReadiness {
        switch event {
        case .lifecycle(.loadState(.loading)):
            if case .loading = r { return r }
            return .loading(progress: nil)
        case .lifecycle(.loadProgress(let p)):
            if case .downloading = r { return r }
            if r == .ready { return r }  // a late progress after ready
            return .loading(progress: p)
        case .lifecycle(.loadState(.ready)):
            return .ready
        case .lifecycle(.loadState(.evicted)):
            return .unknown
        case .lifecycle(.prefillProgress), .lifecycle(.usingLighter), .lifecycle(.generating):
            return r
        case .downloadProgress(let p):
            return .downloading(progress: p)
        case .downloadFinished:
            return .loading(progress: nil)
        case .warmupFinished(let failed):
            if failed { return .failed }
            return r.acceptsRequests ? (r == .unknown ? .ready : r) : .ready
        }
    }

    /// Holds `item` when the model is not ready. Returns false (not held) when the send can go out now.
    public mutating func hold(_ item: Item) -> Bool {
        guard !readiness.acceptsRequests else { return false }
        held.append(item)
        return true
    }

    /// The cancel × (or Stop) on a held send: it is never sent. Returns false when it was not held.
    @discardableResult
    public mutating func cancel(_ item: Item) -> Bool {
        guard let i = held.firstIndex(of: item) else { return false }
        held.remove(at: i)
        return true
    }

    public func isHeld(_ item: Item) -> Bool { held.contains(item) }

    /// Applies `event`; returns the held sends released by it (all of them, in order, once requests are accepted).
    @discardableResult
    public mutating func apply(_ event: ReadinessEvent) -> [Item] {
        readiness = Self.next(readiness, event)
        guard readiness.acceptsRequests, !held.isEmpty else { return [] }
        defer { held.removeAll() }
        return held
    }

    /// Lifecycle + progress of a download (M2's download manager; the unit tests' simulated source): each value
    /// < 1 is `downloadProgress`, the end of the stream `downloadFinished`.
    public static func downloadEvents(_ progress: AsyncStream<Double>) -> AsyncStream<ReadinessEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await p in progress { continuation.yield(.downloadProgress(p)) }
                continuation.yield(.downloadFinished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
