// App-side XPC client for AntiChatEngine.xpc (M1.T05 step 5; architecture §4.2–§4.3), promoted from the M0.T04
// spike. `XPCSession(xpcService:)`, opened lazily by the first request (composer-focus `warmup`), never at
// launch; Hello/HelloAck handshake; one stream per request. On session invalidation (helper crash) every open
// stream ends with `error(engine.restarted)` and the next request reconnects (launchd relaunches the helper;
// restart choreography and crash-loop detection are M1.T12). A `ServerMessage` whose body does not decode ends
// its stream with an error instead of hanging it (CR-S-25).
@_exported import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import os
import Synchronization
import XPC

/// One XPC message from the helper, stamped on arrival in the app.
public struct EngineBatch: Sendable {
    public var items: [StreamItem]
    /// Generated tokens covered by the deltas in `items` (DeltaBatcher count).
    public var tokens: Int
    public var receivedAt: ContinuousClock.Instant

    public init(items: [StreamItem], tokens: Int = 0, receivedAt: ContinuousClock.Instant = .now) {
        self.items = items
        self.tokens = tokens
        self.receivedAt = receivedAt
    }

    public var events: [EngineEvent] {
        items.compactMap { if case .engine(let e) = $0 { e } else { nil } }
    }

    public var lifecycle: [LifecycleEvent] {
        items.compactMap { if case .lifecycle(let e) = $0 { e } else { nil } }
    }

    public var media: [MediaEvent] {
        items.compactMap { if case .media(let e) = $0 { e } else { nil } }
    }

    /// M3.T01: voice events of the batch.
    public var voice: [VoiceEvent] {
        items.compactMap { if case .voice(let e) = $0 { e } else { nil } }
    }

    public var isTerminal: Bool { items.contains(where: \.isTerminal) }
}

public final class EngineClient: EngineService {
    public static var restartedError: AntiChatError { AntiChatError(.engineRestarted, detail: "XPC session invalidated") }

    struct State {
        var session: XPCSession?
        var connecting: Task<HelloAck, Error>?
        var helloWaiter: CheckedContinuation<HelloAck, Error>?
        var streams: [UUID: AsyncStream<EngineBatch>.Continuation] = [:]
        /// Requests waiting for the lazy connection; a Cancel that arrives first drops them.
        var pendingCancels: Set<UUID> = []
        /// Registered requests not yet sent to the helper (lazy connection / reconnect in progress).
        var unsent: Set<UUID> = []
        var generation = 0
        var lastAck: HelloAck?
        /// Order of the last completed handshake across all clients (`probeConnected` asks the newest session).
        var ackOrder: UInt64 = 0
        var probeWaiters: [UUID: CheckedContinuation<HelperProbe, Error>] = [:]
        /// M2.T16: embed / rerank replies.
        var searchWaiters: [UUID: CheckedContinuation<SearchReply, Error>] = [:]
        /// The policy this client's owner set with `setPolicy` (tests, benches: a pinned tier cap). Nil = the session
        /// follows the app's policy (`policyProvider` at the handshake, `pushPolicy` on a change).
        var ownPolicy: SetPolicy?
    }

    private let state = Mutex(State())
    /// Process-wide launchd job bookkeeping (launchd throttles a job whatever client used it): every client records
    /// its helper's start and death, and waits out a throttle before its hello timeout starts counting.
    public static var rotation: ServiceRotation { .shared }
    private let serviceName: String
    private let appBuild: String
    private let onInvalidatedHandler = Mutex<(@Sendable () -> Void)?>(nil)

    public init(serviceName: String = EngineProtocolVersion.serviceName, appBuild: String = "dev") {
        self.serviceName = serviceName
        self.appBuild = appBuild
        Self.live.withLock { $0[ObjectIdentifier(self)] = WeakClient(self) }
    }

    deinit { Self.live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) } }

    /// Every EngineClient alive in this process (M2.T12 live SetPolicy pushes).
    private struct WeakClient: @unchecked Sendable {
        weak var client: EngineClient?
        init(_ c: EngineClient) { client = c }
    }
    private static let live = Mutex<[ObjectIdentifier: WeakClient]>([:])
    private static let ackCounter = Mutex<UInt64>(0)

    /// Called (off-main) when the helper connection dies.
    public var onInvalidated: (@Sendable () -> Void)? {
        get { onInvalidatedHandler.withLock { $0 } }
        set { onInvalidatedHandler.withLock { $0 = newValue } }
    }

    public var isConnected: Bool { state.withLock { $0.session != nil } }
    /// False once the owner set its own policy (`setPolicy`); app policy pushes then skip this client.
    public var followsAppPolicy: Bool { state.withLock { $0.ownPolicy == nil } }
    public var lastAck: HelloAck? { state.withLock { $0.lastAck } }

    public func capabilities() async -> EngineCapabilities? {
        if let ack = lastAck { return ack.capabilities }
        return try? await ensureConnected().capabilities
    }

    // MARK: - Connection

    /// The current handshake, connecting first if needed (lazy; concurrent callers share one attempt).
    @discardableResult
    public func ensureConnected(timeout: Duration = .seconds(10)) async throws -> HelloAck {
        let existing = state.withLock { s -> Task<HelloAck, Error>? in
            if let c = s.connecting { return c }
            if s.session != nil, let ack = s.lastAck { return Task { ack } }
            let t = Task { try await self.connect(timeout: timeout) }
            s.connecting = t
            return t
        }!
        defer { state.withLock { s in if s.session != nil || s.connecting != nil { s.connecting = nil } } }
        return try await existing.value
    }

    /// Opens a fresh session and performs the handshake. `protocolVersion` other than current is for the
    /// version-mismatch test only (the helper then answers `engine.versionMismatch` and exits).
    @discardableResult
    public func connect(timeout: Duration = .seconds(10), protocolVersion: Int = EngineProtocolVersion.current) async throws -> HelloAck {
        // Releasing an active XPCSession traps, so a reconnect cancels the previous one first.
        let (gen, old, orphans) = state.withLock { s -> (Int, XPCSession?, [AsyncStream<EngineBatch>.Continuation]) in
            s.generation += 1
            let old = s.session
            s.session = nil
            s.lastAck = nil
            // The old session's cancellation handler is ignored once the generation moved on, so its open
            // streams must be ended here or their consumers wait forever. Without an old session, the open
            // streams are requests waiting for this very connection: keep them.
            guard old != nil else { return (s.generation, nil, []) }
            let orphans = Array(s.streams.values)
            s.streams.removeAll()
            return (s.generation, old, orphans)
        }
        old?.cancel(reason: "reconnect")
        Self.end(orphans, with: Self.restartedError)
        let session = try XPCSession(
            xpcService: serviceName, targetQueue: nil, options: .inactive,
            incomingMessageHandler: { [weak self] (msg: XPCReceivedMessage) -> (any Encodable)? in
                self?.receive(msg)
                return nil
            },
            cancellationHandler: { [weak self] _ in
                self?.invalidated(generation: gen)
            })
        // fix/hello-timeout: a job whose helper died young is relaunched by launchd only after the rest of its 10 s
        // ThrottleInterval (ServiceRotation), whatever client asks. `timeout` is the budget for the helper to start
        // and answer (measured 0.07–0.12 s cold under 12× `yes` load); the throttle comes on top. Counting it against
        // the budget turned a reconnect right after a helper crash into `engine.helloTimeout` instead of a slower
        // reconnect (a raw client of the primary job 0.4 s after its 0.2 s-old helper was killed: launchd answered
        // after 10.5 s, the 10 s hello had given up).
        let throttle = Self.rotation.throttleRemaining(serviceName)
        if throttle > .zero {
            AppLog.log(.engine, .notice, "\(serviceName): launchd defers the helper's relaunch by \(throttle); hello waits")
        }
        let deadline = timeout + throttle
        try session.activate()
        state.withLock { $0.session = session }
        let hello = Hello(protocolVersion: protocolVersion, appBuild: appBuild)
        let ack: HelloAck = try await withThrowingTaskGroup(of: HelloAck.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<HelloAck, Error>) in
                    self.state.withLock { $0.helloWaiter = c }
                    do { try session.send(ClientMessage.hello(hello)) } catch {
                        self.takeHelloWaiter()?.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                // The continuation task is not cancellation-aware: resume it, or the group (which awaits all
                // children) never returns and the timeout never fires.
                self.takeHelloWaiter()?.resume(throwing: AntiChatError.engine("helloTimeout"))
                throw AntiChatError.engine("helloTimeout")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let order = Self.ackCounter.withLock { $0 += 1; return $0 }
        state.withLock { $0.lastAck = ack; $0.ackOrder = order }
        Self.rotation.connected(serviceName, pid: ack.helperPID)
        // M2.T12: every new helper session starts with the app's scheduler policy (B, keep-alive, allow-over-budget),
        // or with the one its owner set (a reconnect keeps a pinned cap).
        if let p = state.withLock({ $0.ownPolicy }) ?? Self.policyProvider.withLock({ $0 })?() {
            try? session.send(ClientMessage.setPolicy(p))
        }
        return ack
    }

    /// M2.T12: the SetPolicy each new session sends right after the handshake, installed by the composition root
    /// (hardware B + Advanced keep-alive / allow-over-budget). Nil in tests and the bench, which send their own.
    public static let policyProvider = Mutex<(@Sendable () -> SetPolicy?)?>(nil)

    /// M2.T12/T14: re-sends the current policy over every connected session (a keep-alive / allow-over-budget /
    /// power change mid-session). Sessions not yet connected get it at their handshake. Returns the sessions reached.
    /// A client whose owner set its own policy (`setPolicy`: a hosted test's or a bench's tier cap) is skipped:
    /// M9.T05 photo.handoff.T1 — a thermal change in the test host re-sent the host Mac's policy (T4: lowTier false,
    /// its B) mid-job over the test's T1 cap, so the generator stayed beside the detectors (peak 6.1 → 8.1 GB).
    @discardableResult
    public static func pushPolicy(_ policy: SetPolicy? = nil) -> Int {
        guard let p = policy ?? policyProvider.withLock({ $0 })?() else { return 0 }
        let clients = live.withLock { $0.values.compactMap(\.client) }.filter(\.followsAppPolicy)
        return clients.reduce(0) { n, c in c.sendPolicy(p) ? n + 1 : n }
    }

    /// M2.T21 fix: evicts `keys` through the helper's ModelScheduler on every connected session and waits until each
    /// eviction finished (it waits for a running generation's lease). A pack removal calls this before deleting files,
    /// so a loaded model never has its weights pulled from under it. Returns the sessions reached.
    @discardableResult
    public static func evictConnected(_ keys: Set<String>) async -> Int {
        guard !keys.isEmpty else { return 0 }
        let clients = live.withLock { $0.values.compactMap(\.client) }.filter { c in c.state.withLock { $0.lastAck != nil && $0.session != nil } }
        for c in clients {
            for k in keys.sorted() { for await _ in c.evict(key: k) {} }
        }
        return clients.count
    }

    /// M8.T09 System report: the helper's state through the first already-connected session (never starts the helper:
    /// no session → nil, the report says "none"); nil after `timeout` too. With several connected sessions (a rotated
    /// helper's client still alive, a router warm-up client, a hosted test's own client) the newest handshake wins:
    /// `live` is a dictionary, so "first" used to be arbitrary (q66: the hosting app's RouteScorer warm-up client
    /// answered for a test's helper).
    public static func probeConnected(timeout: Duration = .seconds(2)) async -> HelperProbe? {
        let clients = live.withLock { $0.values.compactMap(\.client) }.compactMap { c in
            c.state.withLock { $0.lastAck != nil && $0.session != nil ? (c, $0.ackOrder) : nil }
        }
        guard let c = clients.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        // The probe's continuation is not cancellable: race it unstructured, first answer wins.
        let done = Mutex<CheckedContinuation<HelperProbe?, Never>?>(nil)
        return await withCheckedContinuation { cont in
            done.withLock { $0 = cont }
            Task { let p = try? await c.probe(); done.withLock { $0.take() }?.resume(returning: p) }
            Task { try? await Task.sleep(for: timeout); done.withLock { $0.take() }?.resume(returning: nil) }
        }
    }

    /// M8.T10 Remove everything / Uninstall: ends every live session (the helper exits when its last peer goes).
    public static func disconnectAll() {
        for c in live.withLock({ $0.values.compactMap(\.client) }) { c.disconnect() }
    }

    /// Sends `SetPolicy` on this client's session; false when it is not connected.
    @discardableResult
    public func sendPolicy(_ p: SetPolicy) -> Bool {
        guard let session = state.withLock({ $0.lastAck != nil ? $0.session : nil }) else { return false }
        return (try? session.send(ClientMessage.setPolicy(p))) != nil
    }

    private func takeHelloWaiter() -> CheckedContinuation<HelloAck, Error>? {
        state.withLock { s in
            let w = s.helloWaiter
            s.helloWaiter = nil
            return w
        }
    }

    private static func end(_ streams: [AsyncStream<EngineBatch>.Continuation], with error: AntiChatError) {
        for c in streams {
            c.yield(EngineBatch(items: [.engine(.error(error))]))
            c.finish()
        }
    }

    private func receive(_ msg: XPCReceivedMessage) {
        let now = ContinuousClock.now
        let m: ServerMessage
        do {
            m = try msg.decode(as: ServerMessage.self)
        } catch {
            // CR-S-25: a lost terminal would hang the stream. End the stream the header names, or every open
            // stream when not even the header decodes.
            let id = (try? msg.decode(as: ServerMessageHeader.self))?.requestID
            let err = AntiChatError.engine("undecodableMessage", "\(error)")
            AppLog.log(.engine, .error, "undecodable ServerMessage for \(id?.uuidString ?? "unknown request"): \(error)")
            let victims = state.withLock { s -> [AsyncStream<EngineBatch>.Continuation] in
                if let id { return s.streams.removeValue(forKey: id).map { [$0] } ?? [] }
                let all = Array(s.streams.values)
                s.streams.removeAll()
                return all
            }
            Self.end(victims, with: err)
            if id == nil { takeHelloWaiter()?.resume(throwing: err) }
            return
        }
        switch m.body {
        case .helloAck(let ack):
            takeHelloWaiter()?.resume(returning: ack)
        case .helloRejected(let err):
            takeHelloWaiter()?.resume(throwing: err)
        case .probe(let p):
            guard let id = m.requestID else { return }
            let w = state.withLock { $0.probeWaiters.removeValue(forKey: id) }
            w?.resume(returning: p)
        case .search(let reply):
            guard let id = m.requestID else { return }
            state.withLock { $0.searchWaiters.removeValue(forKey: id) }?.resume(returning: reply)
        case .items(let items, let tokens):
            guard let id = m.requestID else { return }
            let terminal = items.contains(where: \.isTerminal)
            let c = state.withLock { s -> AsyncStream<EngineBatch>.Continuation? in
                terminal ? s.streams.removeValue(forKey: id) : s.streams[id]
            }
            c?.yield(EngineBatch(items: items, tokens: tokens, receivedAt: now))
            if terminal { c?.finish() }
        }
    }

    private func invalidated(generation: Int) {
        let (streams, waiter, probes, current, pid) = state.withLock { s -> ([AsyncStream<EngineBatch>.Continuation], CheckedContinuation<HelloAck, Error>?, [CheckedContinuation<HelperProbe, Error>], Bool, Int32?) in
            guard s.generation == generation else { return ([], nil, [], false, nil) }
            let pid = s.lastAck?.helperPID
            let all = Array(s.streams.values)
            s.streams.removeAll()
            s.session = nil
            s.lastAck = nil
            let w = s.helloWaiter
            s.helloWaiter = nil
            let probes = Array(s.probeWaiters.values)
            s.probeWaiters.removeAll()
            s.searchWaiters.values.forEach { $0.resume(throwing: Self.restartedError) }
            s.searchWaiters.removeAll()
            return (all, w, probes, true, pid)
        }
        guard current else { return }
        // Before onInvalidated: the supervisor picks the next job from this record.
        Self.rotation.died(serviceName, pid: pid)
        probes.forEach { $0.resume(throwing: Self.restartedError) }
        Self.end(streams, with: Self.restartedError)
        waiter?.resume(throwing: Self.restartedError)
        onInvalidated?()
    }

    // MARK: - Requests

    /// Raw batches of one request (bench and M0 lanes). Connects lazily; the stream always ends with one
    /// terminal item.
    public func batches(_ id: UUID, sending message: ClientMessage, cancelOnTermination: Bool = false) -> AsyncStream<EngineBatch> {
        let (stream, cont) = AsyncStream<EngineBatch>.makeStream(bufferingPolicy: .unbounded)
        if cancelOnTermination {
            // M3 review P0-1 / P1-6: a consumer that stops listening (its task cancelled, the stream dropped) ends the
            // helper's work too, instead of leaving it running and buffering into a stream nobody reads.
            cont.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel(id) }
            }
        }
        // The request is sent inside the same critical section that registers it (or, on the lazy path, that
        // checks for an early Cancel), and `cancel` sends its Cancel under that lock too: a Stop can never overtake
        // its request on the wire. The helper ignores a Cancel for a request it has not seen, so an overtaking Stop
        // (e.g. pressed just as the reconnect after a helper restart finished) was lost and the turn ran to
        // maxTokens (flake investigation 2026-11-04).
        let sendError = state.withLock { s -> Error?? in
            s.streams[id] = cont
            guard s.lastAck != nil, let session = s.session else {
                s.unsent.insert(id)
                return .none
            }
            do { try session.send(message); return .some(nil) } catch { return .some(error) }
        }
        switch sendError {
        case .some(let e?): fail(id, e)
        case .some(nil): break
        case .none:
            Task {
                do {
                    try await self.ensureConnected()
                } catch {
                    self.state.withLock { s in
                        s.unsent.remove(id)
                        s.pendingCancels.remove(id)
                    }
                    self.fail(id, error)
                    return
                }
                enum Outcome { case cancelled, sent, failed(Error) }
                let outcome = self.state.withLock { s -> Outcome in
                    s.unsent.remove(id)
                    if s.pendingCancels.remove(id) != nil { return .cancelled }
                    guard let session = s.session, s.streams[id] != nil else { return .failed(Self.restartedError) }
                    do { try session.send(message); return .sent } catch { return .failed(error) }
                }
                switch outcome {
                case .sent: break
                case .failed(let e): self.fail(id, e)
                case .cancelled:
                    let c = self.state.withLock { $0.streams.removeValue(forKey: id) }
                    c?.yield(EngineBatch(items: [.engine(.done(.cancelled))]))
                    c?.finish()
                }
            }
        }
        return stream
    }

    private func fail(_ id: UUID, _ error: Error) {
        let c = state.withLock { $0.streams.removeValue(forKey: id) }
        c?.yield(EngineBatch(items: [.engine(.error(Self.map(error)))]))
        c?.finish()
    }

    public func chatBatches(_ request: ChatRequest) -> AsyncStream<EngineBatch> {
        batches(request.requestID, sending: .chat(request))
    }

    public func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let raw = chatBatches(request)
        let id = request.requestID
        let (stream, cont) = AsyncThrowingStream<EngineEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let pump = Task {
            for await b in raw {
                for item in b.items {
                    switch item {
                    case .engine(let e): cont.yield(e)
                    case .lifecycle(let l): onLifecycle?(l)
                    case .media, .voice: break
                    }
                }
            }
            cont.finish()
        }
        cont.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                self?.cancel(id)
                pump.cancel()
            }
        }
        return stream
    }

    @discardableResult
    public func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        var failure: AntiChatError?
        for await b in warmupBatches(slot) {
            b.lifecycle.forEach { onLifecycle?($0) }
            for e in b.events { if case .error(let err) = e { failure = err } }
        }
        return failure
    }

    public func hint(_ warmup: Warmup) async {
        var w = warmup
        w.predictive = true
        for await _ in batches(w.requestID, sending: .warmup(w)) {}
    }

    public func warmupBatches(_ slot: ModelSlot) -> AsyncStream<EngineBatch> {
        let w = Warmup(modelSlot: slot)
        return batches(w.requestID, sending: .warmup(w))
    }

    /// One voice turn in the helper (M0.T05 spike); the stream ends with `.voiceReport` + `done`.
    public func voice(_ request: VoiceRequest) -> AsyncStream<EngineBatch> {
        batches(request.requestID, sending: .voice(request))
    }

    /// M3.T01: a stream-opening voice message (dictation start, file transcription, session start, speak); the
    /// stream carries `VoiceEvent`s and ends with one terminal engine event.
    public func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> {
        batches(message.requestID, sending: .voiceService(message), cancelOnTermination: true)
    }

    /// M3.T01: a message that acts on an open voice stream (dictation stop, session control/end, speak stop).
    /// Its effects arrive on that stream; false when not connected.
    @discardableResult
    public func voiceSend(_ message: VoiceMessage) -> Bool {
        guard let session = state.withLock({ $0.lastAck != nil ? $0.session : nil }) else { return false }
        return (try? session.send(ClientMessage.voiceService(message))) != nil
    }

    /// M5.T11: a control message for a running media job ([Resume] on a paused video). False when not connected.
    @discardableResult
    public func mediaJobControl(_ c: MediaJobControl) -> Bool {
        guard let session = state.withLock({ $0.lastAck != nil ? $0.session : nil }) else { return false }
        return (try? session.send(ClientMessage.mediaJobControl(c))) != nil
    }

    /// M0.T06: one image job on the helper's sd-server child (media: imageProgress / scheduler / imageResult).
    public func image(_ request: ImageRequest) -> AsyncStream<EngineBatch> {
        batches(request.requestID, sending: .image(request))
    }

    /// M0.T07: one video job (media: videoProgress / scheduler / videoResult).
    public func video(_ request: VideoRequest) -> AsyncStream<EngineBatch> {
        batches(request.requestID, sending: .video(request))
    }

    public func evict(key: String? = nil) -> AsyncStream<EngineBatch> {
        let e = Evict(key: key)
        return batches(e.requestID, sending: .evict(e))
    }

    public func cancel(_ requestID: UUID) {
        state.withLock { s in
            guard s.streams[requestID] != nil else { return }
            // Not on the wire yet (waiting for the lazy connection or a reconnect): drop it before it is sent.
            if s.lastAck == nil || s.unsent.contains(requestID) {
                s.pendingCancels.insert(requestID)
                return
            }
            try? s.session?.send(ClientMessage.cancel(Cancel(requestID: requestID)))
        }
    }

    /// The helper's state (pid, resident models, MediaOutputGate invocations). Tests and diagnostics only.
    public func probe() async throws -> HelperProbe {
        try await ensureConnected()
        let id = UUID()
        guard let s = state.withLock({ $0.session }) else { throw Self.restartedError }
        return try await withCheckedThrowingContinuation { c in
            state.withLock { $0.probeWaiters[id] = c }
            do { try s.send(ClientMessage.probe(requestID: id)) } catch {
                state.withLock { $0.probeWaiters.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    /// M2.T16: unit vectors from the helper's `embed` model (loaded on demand by its scheduler).
    public func embed(_ r: EmbedRequest) async throws -> [[Float]] {
        let reply = try await search(r.requestID, .embed(r))
        if let e = reply.error { throw e }
        return reply.vectors ?? []
    }

    /// M4: compiles the installed ChildSafetyCheck detectors in the helper (install-time; evaluates nothing). Returns
    /// when the compiled form exists (at once when it already did); throws when the files are missing/damaged.
    public func prepareSafety(_ m: SafetyManifest) async throws {
        let r = SafetyPrepareRequest(safety: m)
        if let e = try await search(r.requestID, .prepareSafety(r)).error { throw e }
    }

    /// M2.T16: rerank scores from the helper's `rerank` model (T2+).
    public func rerank(_ r: RerankRequest) async throws -> [Float] {
        let reply = try await search(r.requestID, .rerank(r))
        if let e = reply.error { throw e }
        return reply.scores ?? []
    }

    /// M6.T02: counts by the helper's tokenizer for `slot`; the ⌈chars / 4⌉ estimate if the helper is unreachable.
    public func countTokens(_ texts: [String], slot: ModelSlot) async -> [Int] {
        let r = CountTokensRequest(modelSlot: slot, texts: texts)
        guard let reply = try? await search(r.requestID, .countTokens(r)), reply.error == nil,
              let counts = reply.tokens, counts.count == texts.count else { return texts.map(CountTokensRequest.estimate) }
        return counts
    }

    private func search(_ id: UUID, _ message: ClientMessage) async throws -> SearchReply {
        try await ensureConnected()
        guard let s = state.withLock({ $0.session }) else { throw Self.restartedError }
        return try await withCheckedThrowingContinuation { c in
            state.withLock { $0.searchWaiters[id] = c }
            do { try s.send(message) } catch {
                state.withLock { $0.searchWaiters.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    /// Sets this session's scheduler policy and pins it: app pushes (`pushPolicy`) no longer reach this client, and a
    /// reconnect re-sends it at the handshake.
    public func setPolicy(_ p: SetPolicy) async throws {
        state.withLock { $0.ownPolicy = p }
        try await ensureConnected()
        guard let s = state.withLock({ $0.session }) else { throw Self.restartedError }
        try s.send(ClientMessage.setPolicy(p))
    }

    public func disconnect() {
        let (s, orphans) = state.withLock { st -> (XPCSession?, [AsyncStream<EngineBatch>.Continuation]) in
            let s = st.session
            st.session = nil
            st.lastAck = nil
            st.generation += 1
            let orphans = Array(st.streams.values)
            st.streams.removeAll()
            return (s, orphans)
        }
        s?.cancel(reason: "client disconnect")
        Self.end(orphans, with: Self.restartedError)
    }

    static func map(_ e: Error) -> AntiChatError {
        (e as? AntiChatError) ?? AntiChatError.engine("xpc", "\(e)")
    }
}
