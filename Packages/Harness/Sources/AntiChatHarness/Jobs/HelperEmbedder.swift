// M2.T16: the index's `Embedder` over the helper (XPC EmbedRequest / RerankRequest). The slots come from the
// composition root (catalog `embed` role on every tier, `rerank` on T2+); a nil embed slot means "not installed" and
// makes HybridRetriever fall back to FTS only.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import Foundation

public struct HelperEmbedder: Embedder {
    /// The helper connection for one request (the supervisor's current client in the app, so a helper restart is
    /// followed; a fixed client in the bench).
    public let client: @Sendable () async throws -> EngineClient
    public let embedSlot: @Sendable () -> ModelSlot?
    public let rerankSlot: @Sendable () -> ModelSlot?

    public init(engine: EngineClient, embedSlot: @escaping @Sendable () -> ModelSlot?,
                rerankSlot: @escaping @Sendable () -> ModelSlot? = { nil }) {
        self.client = { engine }
        self.embedSlot = embedSlot
        self.rerankSlot = rerankSlot
    }

    /// M2.T26: the app's engine is an EngineSupervisorClient, not an EngineClient; before this the composition root's
    /// `as? EngineClient` failed, so the pre-router and semantic search never got an embedder in the app.
    public init(supervisor: EngineSupervisorClient, embedSlot: @escaping @Sendable () -> ModelSlot?,
                rerankSlot: @escaping @Sendable () -> ModelSlot? = { nil }) {
        self.client = {
            try await supervisor.ensureConnected()
            return supervisor.current
        }
        self.embedSlot = embedSlot
        self.rerankSlot = rerankSlot
    }

    public func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]] {
        guard let slot = embedSlot() else { throw AntiChatError(.modelMissing, detail: "embed") }
        return try await client().embed(EmbedRequest(modelSlot: slot, texts: texts, kind: kind))
    }

    public func rerank(query: String, documents: [String]) async throws -> [Float]? {
        guard let slot = rerankSlot() else { return nil }
        return try await client().rerank(RerankRequest(modelSlot: slot, query: query, documents: documents))
    }
}
