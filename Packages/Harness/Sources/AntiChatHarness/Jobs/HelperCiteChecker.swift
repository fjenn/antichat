// M7.T03 follow-up, AT-250 c2 (A-M7-T03c option c): the citation entailment check over the helper. The `cite_check`
// slot (MiniCheck, Core ML on CPU + ANE) is sent as one `RerankRequest` per answer with an empty query and
// `claim␟premise` documents (CiteCheckService.pairs), so every sentence × source × window is one batch. The composition
// root sets it (`CiteCheck.use`); nil slot = not installed → the turn keeps the deterministic CitationGrounding only.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatTools
import Foundation

public enum CiteCheck {
    final class Box: @unchecked Sendable {
        static let shared = Box()
        private let lock = NSLock()
        private var scorer: CitationEntailment.Scorer?
        private var missing: (@Sendable () -> Void)?
        func set(_ s: CitationEntailment.Scorer?, missing m: (@Sendable () -> Void)?) { lock.withLock { scorer = s; missing = m } }
        var current: CitationEntailment.Scorer? { lock.withLock { scorer } }
        var onMissing: (@Sendable () -> Void)? { lock.withLock { missing } }
    }

    /// The scorer the turn uses at finalize (nil = no entailment check). `missing` is called when a turn with web
    /// sources finds no installed model (the composition root starts the on-demand download).
    public static func use(_ scorer: CitationEntailment.Scorer?, onMissing: (@Sendable () -> Void)? = nil) {
        Box.shared.set(scorer, missing: onMissing)
    }

    public static var scorer: CitationEntailment.Scorer? { Box.shared.current }
    static func reportMissing() { Box.shared.onMissing?() }

    /// The scorer over the helper for `slot` (nil slot at call time = not installed: throws, the turn keeps the
    /// deterministic check and asks for the download).
    public static func helper(client: @escaping @Sendable () async throws -> EngineClient,
                              slot: @escaping @Sendable () -> ModelSlot?) -> CitationEntailment.Scorer {
        { pairs in
            guard let s = slot() else {
                reportMissing()
                throw AntiChatError(.modelMissing, detail: "cite_check")
            }
            let docs = pairs.map { $0.claim + "\u{1F}" + $0.premise }
            return try await client().rerank(RerankRequest(modelSlot: s, query: "", documents: docs))
        }
    }

    public static func helper(engine: EngineClient, slot: @escaping @Sendable () -> ModelSlot?) -> CitationEntailment.Scorer {
        helper(client: { engine }, slot: slot)
    }

    public static func helper(supervisor: EngineSupervisorClient, slot: @escaping @Sendable () -> ModelSlot?) -> CitationEntailment.Scorer {
        helper(client: {
            try await supervisor.ensureConnected()
            return supervisor.current
        }, slot: slot)
    }
}
