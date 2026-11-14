// The engine as an incognito chat sees it (M1.T20 guard 5): the app's engine with every `ChatRequest` flagged
// `incognito: true` (turns, regenerations, tool-loop steps, compaction summaries alike), so the helper never saves
// the llama-server KV slot of this chat and redacts its logs while the request runs. Keeps the last request in
// memory for the prompt-snapshot check (AT-090 leg 3).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public final class IncognitoEngine: EngineService {
    public let base: any EngineService
    private let last = Mutex<ChatRequest?>(nil)
    private let count = Mutex(0)

    public init(base: any EngineService) { self.base = base }

    /// The most recent request sent through this session (memory only).
    public var lastRequest: ChatRequest? { last.withLock { $0 } }
    public var requestCount: Int { count.withLock { $0 } }

    public func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await base.warmup(slot, onLifecycle: onLifecycle)
    }

    public func hint(_ warmup: Warmup) async { await base.hint(warmup) }

    public func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?)
        -> AsyncThrowingStream<EngineEvent, Error>
    {
        let flagged = IncognitoGuards.flag(request)
        last.withLock { $0 = flagged }
        count.withLock { $0 += 1 }
        return base.chat(flagged, onLifecycle: onLifecycle)
    }

    public func cancel(_ requestID: UUID) { base.cancel(requestID) }

    public func capabilities() async -> EngineCapabilities? { await base.capabilities() }
}
