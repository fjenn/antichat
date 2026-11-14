// `-UseScriptedEngine <path>` in the app (M1.T05 step 6): replays a ScriptedEngine JSONL script in-process,
// with no XPC and no helper, through the same `EngineScriptPlayer` the helper uses. `{"t":"crash"}` reports
// `engine.restarted` (what the app sees when the helper dies).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public final class InProcessScriptedEngine: EngineService {
    public let scriptPath: String
    private let player: EngineScriptPlayer
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])
    private let requests = Mutex(0)
    /// Chat requests received so far (M1.T18 AT-009 (3): an oversize prompt must not reach the engine).
    public var requestCount: Int { requests.withLock { $0 } }

    public init(scriptPath: String) throws {
        self.scriptPath = scriptPath
        player = EngineScriptPlayer(script: try EngineScript(contentsOf: URL(fileURLWithPath: scriptPath)))
    }

    public init(script: EngineScript, path: String = "<inline>") {
        scriptPath = path
        player = EngineScriptPlayer(script: script)
    }

    public func capabilities() async -> EngineCapabilities? { player.script.capabilities }

    @discardableResult
    public func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        do {
            try await player.warmup { out in
                if case .lifecycle(let l) = out { onLifecycle?(l) }
            }
            return nil
        } catch {
            return nil  // cancelled warmup: nothing to report
        }
    }

    public func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let (stream, cont) = AsyncThrowingStream<EngineEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let id = request.requestID
        let player = player
        requests.withLock { $0 += 1 }
        tasks.withLock { t in
            t[id] = Task { [weak self] in
                await player.play(request) { out in
                    switch out {
                    case .engine(let e):
                        cont.yield(e)
                        if e.isTerminal { cont.finish() }
                    case .lifecycle(let l): onLifecycle?(l)
                    case .crash:
                        cont.yield(.error(AntiChatError(.engineRestarted, detail: "scripted crash")))
                        cont.finish()
                    }
                }
                cont.finish()
                _ = self?.tasks.withLock { $0.removeValue(forKey: id) }
            }
        }
        cont.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.cancel(id) }
        }
        return stream
    }

    public func cancel(_ requestID: UUID) {
        let t = tasks.withLock { $0[requestID] }
        t?.cancel()
    }
}
