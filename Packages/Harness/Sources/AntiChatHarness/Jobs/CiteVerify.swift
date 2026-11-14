// AT-250 c2 attempt 6 (A-M7-T03c): the generative per-sentence citation verifier (CitationVerifier) on the turn's
// own chat model. The composition root turns it on (`CiteVerify.use(true)`); off = the turn stops after the MiniCheck
// entailment check (tests with scripted engines, which answer only the turn's own requests).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatTools
import Foundation

public enum CiteVerify {
    final class Box: @unchecked Sendable {
        static let shared = Box()
        private let lock = NSLock()
        private var on = false
        func set(_ v: Bool) { lock.withLock { on = v } }
        var enabled: Bool { lock.withLock { on } }
    }

    public static func use(_ on: Bool) { Box.shared.set(on) }
    public static var enabled: Bool { Box.shared.enabled }

    /// One prefix-cache session for every verifier request, so the pass takes at most one of the engine's session
    /// slots and never the chat's own (MLXPrefixCache keeps 2 sessions).
    public static let sessionID = UUID(uuidString: "A7250C2A-0006-4E7F-9C1D-000000000250")!

    /// The verifier's generator over `engine` with `slot` (greedy, reasoning off, no system layer).
    public static func generator(engine: any EngineService, slot: @escaping @Sendable () -> ModelSlot) -> CitationVerifier.Generator {
        { prompt, maxTokens in
            let request = ChatRequest(sessionID: sessionID, modelSlot: slot(),
                                      messages: [ChatMessage(role: .user, content: prompt)], reasoning: .off,
                                      sampling: Sampling(temperature: 0, topP: 1, maxTokens: maxTokens, seed: 7))
            return try await withTaskCancellationHandler {
                var text = ""
                for try await event in engine.chat(request) {
                    switch event {
                    case .textDelta(let s): text += s
                    case .error(let e): throw e
                    case .done: return text
                    default: break
                    }
                }
                return text
            } onCancel: {
                engine.cancel(request.requestID)
            }
        }
    }
}
