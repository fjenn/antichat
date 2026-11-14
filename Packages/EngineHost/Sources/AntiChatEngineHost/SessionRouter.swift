// One app session (M1.T05 step 4). Decodes each `ClientMessage`, runs one Task per request and answers
// `Cancel{requestID}` within ≤ 300 ms (NFR-U6): the request Task is cancelled (propagating into the adapter)
// and, if it has not ended 250 ms later (e.g. still waiting for a model load), the router ends the stream
// with `done(cancelled)` itself. A request is registered in the same critical section that creates its Task,
// so a Cancel can never fall into a gap between "started" and "registered" (CR-S-22). Every stream gets
// exactly one terminal event; anything a request emits after its terminal is dropped.
import AntiChatEngineProtocol
import AntiChatEngines
import AntiChatFoundation
import Darwin
import Foundation
import Synchronization
import XPC

final class SessionRouter: XPCPeerHandler, Sendable {
    typealias Input = XPCReceivedMessage
    typealias Output = any Encodable

    /// Grace before the router itself ends a cancelled request (the Task normally ends within milliseconds).
    static let cancelGrace = Duration.milliseconds(250)

    struct Entry {
        var task: Task<Void, Never>?
        var terminated = false
        /// Image/video jobs cancel cooperatively (the job polls the flag and reports `cancelled`).
        var mediaCancel: EngineRuntime.CancelFlag?
    }

    let session: XPCSession
    let core: EngineCore
    let lifecycle: HelperLifecycle
    private let entries = Mutex<[UUID: Entry]>([:])
    /// CR-S-23: the latest `SetPolicy` application. Requests that arrive after a SetPolicy wait for it, so a
    /// chat sent right after a budget change is scheduled under the new budget B (XPC delivers one session's
    /// messages in order; the barrier keeps that order across the async budget update).
    private let policyBarrier = Mutex<Task<Void, Never>?>(nil)
    /// M3 review P2-1: the messages acting on one voice stream run in arrival order (`VoiceRouting.swift`).
    let voiceOrder = VoiceOrder()

    init(session: XPCSession, core: EngineCore, lifecycle: HelperLifecycle) {
        self.session = session
        self.core = core
        self.lifecycle = lifecycle
        Task { await lifecycle.sessionOpened() }
    }

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        do {
            handle(try message.decode(as: ClientMessage.self))
        } catch {
            AppLog.log(.engine, .error, "undecodable ClientMessage: \(error)")
        }
        return nil
    }

    func handleCancellation(error: XPCRichError) {
        // The app went away: nothing streams to it any more, so stop its work.
        let tasks = entries.withLock { s -> [Task<Void, Never>] in
            let t = s.values.compactMap(\.task)
            for (_, e) in s { e.mediaCancel?.cancel() }
            s.removeAll()
            return t
        }
        tasks.forEach { $0.cancel() }
        Task { await lifecycle.sessionClosed() }
    }

    // MARK: - Sending

    private func send(_ m: ServerMessage) {
        do { try session.send(m) } catch {
            AppLog.log(.engine, .error, "send failed: \(error)")
        }
    }

    /// Sends `items` for request `id` unless it already terminated; marks it terminated on a terminal item.
    private func emit(_ id: UUID, _ items: [StreamItem], tokens: Int) {
        let ok = entries.withLock { s -> Bool in
            guard var e = s[id], !e.terminated else { return false }
            if items.contains(where: \.isTerminal) {
                e.terminated = true
                s[id] = e
            }
            return true
        }
        if ok { send(.items(id, items, tokens: tokens)) }
    }

    func emitter(_ id: UUID) -> EngineCore.Emit {
        { [weak self] items, tokens in self?.emit(id, items, tokens: tokens) }
    }

    /// Registers request `id` and starts its Task in one critical section (CR-S-22).
    func start(_ id: UUID, mediaCancel: EngineRuntime.CancelFlag? = nil, _ body: @escaping @Sendable () async -> Void) {
        let duplicate = entries.withLock { s -> Bool in
            if s[id] != nil { return true }
            var e = Entry(mediaCancel: mediaCancel)
            let barrier = policyBarrier.withLock { $0 }
            e.task = Task { [weak self] in
                await barrier?.value
                await body()
                self?.finish(id)
            }
            s[id] = e
            return false
        }
        if duplicate {
            send(.items(id, [.engine(.error(.engine("duplicateRequestID", id.uuidString)))]))
        }
    }

    private func finish(_ id: UUID) {
        let unterminated = entries.withLock { s -> Bool in
            let e = s.removeValue(forKey: id)
            return e.map { !$0.terminated } ?? false
        }
        // Every body emits a terminal; this only guards against a body that returned without one.
        if unterminated { send(.items(id, [.engine(.error(.engine("noTerminal")))])) }
    }

    private func cancel(_ id: UUID) {
        let (task, media) = entries.withLock { s in (s[id]?.task, s[id]?.mediaCancel) }
        if let media {
            media.cancel()
            return
        }
        guard let task else { return }
        task.cancel()
        Task { [weak self] in
            try? await Task.sleep(for: Self.cancelGrace)
            self?.emit(id, [.engine(.done(.cancelled))], tokens: 0)
        }
    }

    // MARK: - Routing

    func handle(_ message: ClientMessage) {
        switch message {
        case .hello(let h):
            guard h.protocolVersion == EngineProtocolVersion.current else {
                let err = AntiChatError.versionMismatch(helper: EngineProtocolVersion.current, app: h.protocolVersion)
                AppLog.log(.engine, .error, "Hello refused: \(err); exiting")
                send(ServerMessage(requestID: nil, body: .helloRejected(err)))
                // Half-updated install guard (architecture §4.3): never mix versions. The delay lets the reply go out.
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(200))
                    exit(3)
                }
                return
            }
            if let pid = h.clientPID {  // M9.T05 (NFR-B5): the app's own GPU use is never "another app"
                let runtime = core.runtime
                Task { await runtime.addClient(pid: pid) }
            }
            send(
                ServerMessage(
                    requestID: nil,
                    body: .helloAck(
                        HelloAck(
                            capabilities: core.capabilities, helperPID: getpid(),
                            recommendedMaxWorkingSetSize: MemoryProbe.recommendedMaxWorkingSetSize,
                            engineInstanceID: core.mediaJobs.engineInstanceID))))
        case .setPolicy(let p):
            core.batch.withLock { $0 = p.batch }
            let scheduler = core.scheduler, runtime = core.runtime, pressure = core.pressure
            policyBarrier.withLock { barrier in
                let previous = barrier
                barrier = Task {
                    await previous?.value
                    await scheduler.setPolicy(p)  // M2.T12: B, keep-alive, low power, allow-over-budget
                    await runtime.setThermal(p.thermal ?? .nominal)  // M2.T14: NFR-B3 pacing
                    #if DEBUG || ANTICHAT_PERF_HARNESS
                    if let t = p.testPressure, let level = PressureLevel(name: t) {  // -FakePressure (M2.T14)
                        await pressure.handle(level, source: "test")
                    }
                    #endif
                }
            }
        case .cancel(let c):
            cancel(c.requestID)
        case .chat(let req):
            let core = core, emit = emitter(req.requestID)
            // M1.T20: an incognito request runs with log redaction on (no content-bearing line reaches the file log).
            start(req.requestID) { await AppLog.$incognito.withValue(req.incognito) { await core.runChat(req, emit: emit) } }
        case .warmup(let w):
            let core = core, emit = emitter(w.requestID)
            start(w.requestID) { await core.runWarmup(w, emit: emit) }
        case .evict(let e):
            let core = core, emit = emitter(e.requestID)
            start(e.requestID) { await core.runEvict(e, emit: emit) }
        case .voice(let req):
            let core = core, emit = emitter(req.requestID)
            start(req.requestID) { await core.runVoice(req, emit: emit) }
        case .image(let req):
            let flag = EngineRuntime.CancelFlag()
            let core = core, emit = emitter(req.requestID)
            start(req.requestID, mediaCancel: flag) { await core.runImage(req, cancel: flag, emit: emit) }
        case .mediaJob(let job):
            let flag = EngineRuntime.CancelFlag()
            let core = core, emit = emitter(job.requestID)
            start(job.requestID, mediaCancel: flag) { await core.runMediaJob(job, cancel: flag, emit: emit) }
        case .prepareSafety(let req):
            let core = core
            Task { [weak self] in
                let outcome = await core.prepareSafety(req.safety)
                let error: AntiChatError? = outcome == .failed ? AntiChatError.engine("safetyPrepareFailed", nil) : nil
                self?.send(ServerMessage(requestID: req.requestID, body: .search(SearchReply(error: error))))
            }
        case .embed(let req):
            let core = core
            Task { [weak self] in
                let reply = await core.runEmbed(req)
                self?.send(ServerMessage(requestID: req.requestID, body: .search(reply)))
            }
        case .rerank(let req):
            let core = core
            Task { [weak self] in
                let reply = await core.runRerank(req)
                self?.send(ServerMessage(requestID: req.requestID, body: .search(reply)))
            }
        case .countTokens(let req):
            let core = core
            Task { [weak self] in
                let reply = await core.runtime.tokenCounter.reply(req)
                self?.send(ServerMessage(requestID: req.requestID, body: .search(reply)))
            }
        case .probe(let id):
            let core = core, lifecycle = lifecycle
            Task { [weak self] in
                let probe = HelperProbe(
                    pid: getpid(), residentModels: await core.runtime.residentModels(),
                    mediaGateInvocations: MediaOutputGate.trace.count, sessions: await lifecycle.sessions,
                    pinnedPrefixes: await core.runtime.pinnedPrefixCount(),
                    residentBytes: await core.runtime.residentBytes(), loadTimesMs: await core.runtime.recentLoadTimesMs(),
                    footprintBytes: EngineRuntime.physFootprint(getpid()), mtlAllocatedBytes: MemoryProbe.mtlAllocatedBytes)
                self?.send(ServerMessage(requestID: id, body: .probe(probe)))
            }
        case .video(let req):
            let flag = EngineRuntime.CancelFlag()
            let core = core, emit = emitter(req.requestID)
            start(req.requestID, mediaCancel: flag) { await core.runVideo(req, cancel: flag, emit: emit) }
        case .mediaJobControl(let c):
            // M5.T11: [Resume] on a paused video card (one video job at a time; the stream id is informational).
            let runtime = core.runtime
            if c.action == .resume { Task { await runtime.resumeVideo() } }
        case .voiceService(let m):
            routeVoice(m)  // M3.T01 (VoiceRouting.swift)
        }
    }
}
