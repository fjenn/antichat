// EngineSupervisorClient (M1.T12 step 5; NFR-S4, R-208 AC1): the app's EngineService. Wraps one EngineClient per
// launchd job of the helper (AntiChatEngine.xpc and AntiChatEngineStandby.xpc, A-M1-T12a) and owns the restart
// choreography:
//   1. the XPC session of the current helper is invalidated (crash, `kill -9`) → EngineClient has already ended
//      every in-flight stream with `error(engine.restarted)` (recovery [Retry]); TurnController marks those turns
//      `interrupted` and renders EngineRestartedNotice;
//   2. the supervisor records the restart, picks the job launchd will start without its respawn throttle
//      (`ServiceRotation`: a job that ran < 10 s is relaunched only after the rest of its 10 s ThrottleInterval,
//      measured 9.1–10.1 s, build/at/AT-NFR-S4/), re-creates the session at once and waits for HelloAck;
//   3. it re-sends `Warmup` for the last warmed slot, so the next send does not pay the load;
//   4. ≥ `crashLoop.maxRestarts` restarts within `crashLoop.window` (3 in 60 s) → `engine.crashLoop` banner; the
//      session is still re-created (cheap), but no automatic Warmup (it might be the load that crashes).
// Before a request reaches the helper, the memory-fit guard (MemoryFitGuard, step 7) may swap in a lighter
// catalog entry (`usingLighter` event) or refuse the turn with `model.notEnoughMemory` (no load attempted).
// M2.T12: before that, the load gate (ModelLoadGate: store load check, update-trial verdict and rollback).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public final class EngineSupervisorClient: EngineService {
    public struct CrashLoopPolicy: Sendable {
        public var maxRestarts: Int
        public var window: Duration
        public init(maxRestarts: Int = 3, window: Duration = .seconds(60)) {
            self.maxRestarts = maxRestarts
            self.window = window
        }
        public static let standard = CrashLoopPolicy()
    }

    public enum State: Sendable, Equatable {
        case idle
        case ready(pid: Int32, service: String)
        case restarting(service: String)
        case crashLoop(restarts: Int)
    }

    public enum Event: Sendable, Equatable {
        /// The helper died; `service` is the job being started instead.
        case restarting(service: String, restartsInWindow: Int)
        /// A relaunched helper answered HelloAck `latency` seconds after the invalidation was noticed.
        case restarted(pid: Int32, service: String, latency: Double)
        /// The relaunch failed (no HelloAck); the next request retries lazily.
        case restartFailed(service: String, error: AntiChatError)
        /// ≥ maxRestarts within the window: show the `engine.crashLoop` banner.
        case crashLoop(restarts: Int)
        /// The memory-fit guard replaced `from` with the lighter `to` for this request (`model.usingLighter`).
        case usingLighter(requestID: UUID, from: String, to: String)
    }

    struct Inner {
        var clients: [String: EngineClient] = [:]
        var current: String
        var state: State = .idle
        var restarts: [ContinuousClock.Instant] = []
        var lastWarm: ModelSlot?
        var observers: [UUID: AsyncStream<Event>.Continuation] = [:]
        var restartTask: Task<Void, Never>?
    }

    public let services: [String]
    public let crashLoop: CrashLoopPolicy
    public let rotation: ServiceRotation
    public let fitGuard: MemoryFitGuard?
    /// M2.T12: the load gate for this client (tests); nil = `ModelLoadGate.shared` (the composition root's).
    public let loadGate: (any ModelLoadGating)?
    private let appBuild: String
    private let inner: Mutex<Inner>

    public init(
        services: [String] = EngineProtocolVersion.serviceNames, appBuild: String = "dev",
        crashLoop: CrashLoopPolicy = .standard, rotation: ServiceRotation = .shared, fitGuard: MemoryFitGuard? = nil,
        loadGate: (any ModelLoadGating)? = nil
    ) {
        self.loadGate = loadGate
        precondition(!services.isEmpty)
        self.services = services
        self.crashLoop = crashLoop
        self.rotation = rotation
        self.fitGuard = fitGuard
        self.appBuild = appBuild
        inner = Mutex(Inner(current: rotation.pick(services)))
    }

    deinit {
        let clients = inner.withLock { Array($0.clients.values) }
        clients.forEach { $0.disconnect() }
    }

    public var state: State { inner.withLock { $0.state } }
    public var currentService: String { inner.withLock { $0.current } }

    /// The client for the job currently in use (created lazily; its session opens on the first request).
    public var current: EngineClient {
        let (client, service, created) = inner.withLock { s -> (EngineClient, String, Bool) in
            if let c = s.clients[s.current] { return (c, s.current, false) }
            let c = EngineClient(serviceName: s.current, appBuild: appBuild)
            s.clients[s.current] = c
            return (c, s.current, true)
        }
        if created { watch(client, service: service) }
        return client
    }

    /// Every supervisor event from now on (one stream per call).
    public func events() -> AsyncStream<Event> {
        let (stream, cont) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        inner.withLock { $0.observers[id] = cont }
        cont.onTermination = { [weak self] _ in self?.inner.withLock { _ = $0.observers.removeValue(forKey: id) } }
        return stream
    }

    private func emit(_ e: Event) {
        let obs = inner.withLock { Array($0.observers.values) }
        obs.forEach { $0.yield(e) }
    }

    private func watch(_ client: EngineClient, service: String) {
        client.onInvalidated = { [weak self] in self?.helperDied(service: service) }
    }

    // MARK: - Restart choreography (step 5)

    /// Connects the current job (lazy-connect entry point for tests and the bench) and records its start.
    @discardableResult
    public func ensureConnected(timeout: Duration = .seconds(15)) async throws -> HelloAck {
        let client = current
        let service = currentService
        let ack = try await client.ensureConnected(timeout: timeout)
        rotation.connected(service, pid: ack.helperPID)
        inner.withLock { s in if case .crashLoop = s.state {} else { s.state = .ready(pid: ack.helperPID, service: service) } }
        return ack
    }

    func helperDied(service: String) {
        let noticed = ContinuousClock.now
        // `.shared` already has this death: every EngineClient records its helper's into it (fix/hello-timeout).
        if rotation !== ServiceRotation.shared { rotation.died(service, at: noticed) }
        let (next, count, looping) = inner.withLock { s -> (String, Int, Bool) in
            s.restarts.append(noticed)
            s.restarts.removeAll { noticed - $0 > crashLoop.window }
            let looping = s.restarts.count >= crashLoop.maxRestarts
            s.current = rotation.pick(services, preferring: service)
            s.state = looping ? .crashLoop(restarts: s.restarts.count) : .restarting(service: s.current)
            return (s.current, s.restarts.count, looping)
        }
        AppLog.log(.engine, .error, "engine helper (\(service)) died; restart \(count) in window → \(next)")
        emit(.restarting(service: next, restartsInWindow: count))
        if looping { emit(.crashLoop(restarts: count)) }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let ack = try await self.ensureConnected()
                let latency = EngineSupervisorClient.secs(ContinuousClock.now - noticed)
                AppLog.log(.engine, .notice, "engine helper relaunched as pid \(ack.helperPID) (\(next)) in \(latency) s")
                self.emit(.restarted(pid: ack.helperPID, service: next, latency: latency))
                if !looping, let slot = self.inner.withLock({ $0.lastWarm }) {
                    await self.current.warmup(slot, onLifecycle: nil)
                }
            } catch {
                self.emit(.restartFailed(service: next, error: EngineClient.map(error)))
            }
        }
        inner.withLock { $0.restartTask = task }
    }

    /// Waits for an ongoing restart (tests).
    public func waitForRestart() async {
        await inner.withLock { $0.restartTask }?.value
    }

    /// Restart count inside the crash-loop window, as of now.
    public var restartsInWindow: Int {
        let now = ContinuousClock.now
        return inner.withLock { s in s.restarts.filter { now - $0 <= crashLoop.window }.count }
    }

    // MARK: - EngineService

    public func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        // M2.T12: the load gate (Repair.loadCheck + update rollback verdict) runs before the fit guard.
        guard let gate = loadGate ?? ModelLoadGate.current else { return await guardedWarmup(slot, onLifecycle: onLifecycle) }
        let s: ModelSlot
        switch await gate.prepare(slot) {
        case .failure(let e): return e
        case .success(let g): s = g
        }
        let verdict = LoadVerdict(gate: gate, slot: s)
        let err = await guardedWarmup(s) { l in
            verdict.observe(l)
            onLifecycle?(l)
        }
        if err != nil { verdict.failed() }
        await verdict.settle()
        return err
    }

    public func hint(_ warmup: Warmup) async { await current.hint(warmup) }

    public func countTokens(_ texts: [String], slot: ModelSlot) async -> [Int] {
        _ = try? await ensureConnected()
        return await current.countTokens(texts, slot: slot)
    }

    private func guardedWarmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        var slot = slot
        if let g = fitGuard {
            switch g.check(slot) {
            case .fits: break
            case .lighter(let lighter, _): slot = lighter
            case .notEnoughMemory(let e): return e
            }
        }
        inner.withLock { $0.lastWarm = slot }
        return await current.warmup(slot, onLifecycle: onLifecycle)
    }

    public func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        guard let gate = loadGate ?? ModelLoadGate.current else { return guardedChat(request, onLifecycle: onLifecycle) }
        let (stream, cont) = AsyncThrowingStream<EngineEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            var req = request
            switch await gate.prepare(request.modelSlot) {
            case .failure(let e):
                cont.yield(.error(e))
                cont.finish()
                return
            case .success(let s): req.modelSlot = s
            }
            let verdict = LoadVerdict(gate: gate, slot: req.modelSlot)
            let inner = self.guardedChat(req) { l in
                verdict.observe(l)
                onLifecycle?(l)
            }
            do {
                for try await e in inner {
                    if case .error = e { verdict.failed() }
                    cont.yield(e)
                }
                await verdict.settle()
                cont.finish()
            } catch {
                await verdict.settle()
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }

    private func guardedChat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        var request = request
        if let g = fitGuard {
            switch g.check(request.modelSlot) {
            case .fits:
                break
            case .lighter(let lighter, let from):
                request.modelSlot = lighter
                emit(.usingLighter(requestID: request.requestID, from: from, to: lighter.key))
            case .notEnoughMemory(let e):
                // The user message stays (the caller keeps it); nothing reaches the helper, so no load is tried.
                return AsyncThrowingStream { c in
                    c.yield(.error(e))
                    c.finish()
                }
            }
        }
        // M2.T13 (NFR-R5): the helper's scheduler chose a lighter fallback → the same `usingLighter` event as the guard's.
        let id = request.requestID
        return current.chat(request) { [weak self] l in
            if case .usingLighter(let from, let to) = l { self?.emit(.usingLighter(requestID: id, from: from, to: to)) }
            onLifecycle?(l)
        }
    }

    public func cancel(_ requestID: UUID) {
        // The stream lives on whichever client served it; cancel is a no-op on the others.
        let clients = inner.withLock { Array($0.clients.values) }
        clients.forEach { $0.cancel(requestID) }
    }

    public func capabilities() async -> EngineCapabilities? { await current.capabilities() }

    /// M3.T03: voice streams and their stop / control messages go to the current helper.
    public func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> { current.voiceStream(message) }

    @discardableResult
    public func voiceSend(_ message: VoiceMessage) -> Bool { current.voiceSend(message) }

    public func disconnect() {
        let clients = inner.withLock { Array($0.clients.values) }
        clients.forEach { $0.disconnect() }
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// Which helper job to connect (process-wide: launchd throttles a job whatever client used it). launchd defers the
/// relaunch of a job that ran `r` < 10 s until `death + (10 − r)` (ThrottleInterval); this picks the job that can
/// start soonest, preferring the primary when both are free.
public final class ServiceRotation: Sendable {
    public static let shared = ServiceRotation()
    /// launchd's default ThrottleInterval for XPC services (not configurable from an XPC Info.plist).
    public static let throttleInterval: Duration = .seconds(10)

    struct Record {
        var started: ContinuousClock.Instant?
        var pid: Int32 = 0
        var freeAt: ContinuousClock.Instant?
    }

    private let records = Mutex<[String: Record]>([:])

    public init() {}

    /// A HelloAck from `pid` on `service` (a new pid = a new helper process started about now).
    public func connected(_ service: String, pid: Int32, at now: ContinuousClock.Instant = .now) {
        records.withLock { r in
            var rec = r[service] ?? Record()
            if rec.pid != pid {
                rec.pid = pid
                rec.started = now
            }
            r[service] = rec
        }
    }

    /// The helper of `service` died at `now`. With `pid` (the helper the dying session had acked), a death that is not
    /// the recorded helper's is ignored: every session to the same helper reports it (fix/hello-timeout: each
    /// EngineClient records into `.shared`), and a second record would restart the throttle as if a 0 s helper died.
    public func died(_ service: String, pid: Int32? = nil, at now: ContinuousClock.Instant = .now) {
        records.withLock { r in
            var rec = r[service] ?? Record()
            if let pid, rec.pid != pid { return }
            let ran = rec.started.map { now - $0 } ?? .zero
            rec.freeAt = ran >= Self.throttleInterval ? now : now + (Self.throttleInterval - ran)
            rec.pid = 0
            rec.started = nil
            r[service] = rec
        }
    }

    /// When launchd will start `service` again without delay.
    public func freeAt(_ service: String) -> ContinuousClock.Instant? { records.withLock { $0[service]?.freeAt } }

    /// How long launchd still defers a start of `service` (zero when free). A handshake with that job cannot start
    /// before then, so it is added to the hello timeout (EngineClient.connect), never counted against it.
    public func throttleRemaining(_ service: String, now: ContinuousClock.Instant = .now) -> Duration {
        guard let free = freeAt(service), free > now else { return .zero }
        return free - now
    }

    /// The job to use now: the first free one in `services` order, else the one free soonest; `preferring` (the
    /// job that just died) loses ties so a restart moves to the other job.
    public func pick(_ services: [String], preferring died: String? = nil, now: ContinuousClock.Instant = .now) -> String {
        let free = records.withLock { r in services.map { (s: $0, at: r[$0]?.freeAt ?? now) } }
        let candidates = free.filter { $0.s != died } + free.filter { $0.s == died }
        if let ready = candidates.first(where: { $0.at <= now }) { return ready.s }
        return candidates.min { $0.at < $1.at }!.s
    }
}
