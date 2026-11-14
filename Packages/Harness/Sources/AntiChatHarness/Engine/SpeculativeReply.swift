// NFR-V1 (voice conversation, A-M3-T09c): speculative generation during the end-of-turn wait. When the user pauses,
// the session's pause transcript arrives (`VoiceEvent.provisionalTranscript`) up to ~0.8 s before the turn ends; the
// chat starts the request that transcript would send and keeps every event in a buffer. Nothing of it is shown,
// written, spoken or acted on (a tool call in it is only an event in the buffer). When the turn's real request is
// ready, `take(matching:)` hands the buffered + live stream over **only if the real request is identical** (every
// field but the request id: same prompt, conversation, user text, tools, sampling, session); otherwise the speculation
// is cancelled and dropped silently, and the real request goes to the engine as usual. Audio is never involved: the
// reply reaches the voice helper only through the turn that adopted the stream, so a discarded speculation is never
// heard.
import AntiChatEngineProtocol
import Foundation
import Synchronization

/// One speculative chat request at a time; the newest `start` replaces (and cancels) the previous one.
public final class SpeculativeReply: Sendable {
    public enum Item: Sendable, Equatable {
        case event(EngineEvent)
        case lifecycle(LifecycleEvent)
    }

    private struct Pending: Sendable {
        var request: ChatRequest
        var buffer: [Item] = []
        var finished = false
        var error: (any Error)?
        var task: Task<Void, Never>?
        /// The reply text so far and who hears about it (the voice helper's presynthesis), while unadopted.
        var text = ""
        var onText: (@Sendable (String) -> Void)?
    }

    private struct Adopted: Sendable {
        var sink: AsyncThrowingStream<Item, Error>.Continuation
        var task: Task<Void, Never>?
    }

    private struct State: Sendable {
        var pending: Pending?
        /// Speculations handed to a turn, by request id (events go straight to the turn's stream).
        var adopted: [UUID: Adopted] = [:]
    }

    private let state = Mutex(State())
    private let cancelRequest: @Sendable (UUID) -> Void
    private let open: @Sendable (ChatRequest, @escaping @Sendable (LifecycleEvent) -> Void) -> AsyncThrowingStream<EngineEvent, Error>

    public init(engine: any EngineService) {
        open = { req, life in engine.chat(req, onLifecycle: life) }
        cancelRequest = { engine.cancel($0) }
    }

    /// The request currently speculated and not yet adopted (nil when none).
    public var pending: ChatRequest? { state.withLock { $0.pending?.request } }

    /// Characters of speculative text reported to `onText` at most (the first clause is all the helper uses).
    static let textLimit = 400

    /// Starts `request` speculatively (cancels and drops a previous, unadopted speculation). `onText` hears the
    /// speculative reply text so far (up to `textLimit` characters) until the speculation is adopted or dropped.
    public func start(_ request: ChatRequest, onText: (@Sendable (String) -> Void)? = nil) {
        cancel()
        let id = request.requestID
        state.withLock { $0.pending = Pending(request: request, onText: onText) }
        let stream = open(request) { [weak self] l in self?.append(.lifecycle(l), id: id) }
        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                for try await e in stream { self?.append(.event(e), id: id) }
                self?.end(nil, id: id)
            } catch {
                self?.end(error, id: id)
            }
        }
        let current = state.withLock { s -> Bool in
            if s.pending?.request.requestID == id { s.pending?.task = task; return true }
            if s.adopted[id] != nil { s.adopted[id]?.task = task; return true }
            return false
        }
        if !current { task.cancel() }
    }

    /// Drops the unadopted speculation (its engine request is cancelled). An adopted one belongs to its turn.
    public func cancel() {
        let dropped: Pending? = state.withLock { s in
            defer { s.pending = nil }
            return s.pending
        }
        guard let dropped else { return }
        dropped.task?.cancel()
        if !dropped.finished { cancelRequest(dropped.request.requestID) }
    }

    /// Hands the speculation over when `request` equals it in every field but the request id: returns the speculative
    /// request (its id is the engine's) and its items, buffered first, then live. Any other request cancels it (nil).
    public func take(matching request: ChatRequest) -> (request: ChatRequest, items: AsyncThrowingStream<Item, Error>)? {
        guard let spec = pending else { return nil }
        guard Self.same(spec, request) else {
            cancel()
            return nil
        }
        let (stream, cont) = AsyncThrowingStream<Item, Error>.makeStream(bufferingPolicy: .unbounded)
        let id = spec.requestID
        let taken: Bool = state.withLock { s in
            guard let p = s.pending, p.request.requestID == id else { return false }
            s.pending = nil
            for item in p.buffer { cont.yield(item) }
            if p.finished {
                if let e = p.error { cont.finish(throwing: e) } else { cont.finish() }
            } else {
                s.adopted[id] = Adopted(sink: cont, task: p.task)
            }
            return true
        }
        guard taken else {
            cont.finish()
            return nil
        }
        let cancelRequest = cancelRequest
        cont.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            // The adopting turn stopped consuming (Stop / cancel): the engine request ends with it.
            let adopted = self?.state.withLock { s -> Adopted? in
                defer { s.adopted[id] = nil }
                return s.adopted[id]
            }
            guard let adopted else { return }
            adopted.task?.cancel()
            cancelRequest(id)
        }
        return (spec, stream)
    }

    /// Equal in every field but `requestID`.
    public static func same(_ a: ChatRequest, _ b: ChatRequest) -> Bool {
        var b = b
        b.requestID = a.requestID
        return a == b
    }

    private func append(_ item: Item, id: UUID) {
        let report: (text: String, to: @Sendable (String) -> Void)? = state.withLock { s in
            guard s.pending?.request.requestID == id else {
                s.adopted[id]?.sink.yield(item)
                return nil
            }
            s.pending?.buffer.append(item)
            guard case .event(.textDelta(let d)) = item, !d.isEmpty, let to = s.pending?.onText,
                  let before = s.pending?.text, before.count < Self.textLimit else { return nil }
            s.pending?.text = before + d
            return (before + d, to)
        }
        if let report { report.to(report.text) }
    }

    private func end(_ error: (any Error)?, id: UUID) {
        state.withLock { s in
            if s.pending?.request.requestID == id {
                s.pending?.finished = true
                s.pending?.error = error
            } else if let a = s.adopted.removeValue(forKey: id) {
                if let error { a.sink.finish(throwing: error) } else { a.sink.finish() }
            }
        }
    }
}
