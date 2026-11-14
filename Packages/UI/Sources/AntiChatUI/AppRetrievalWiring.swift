// The composition root's retrieval wiring (called from `AntiChatApp.init`; `AppRetrievalWiringTests` runs the same
// function): every search / retrieval consumer of the app gets the helper's embedder here, in one place.
// Consumers: ⌘K semantic search + its background index (M2.T16), the semantic pre-router (M2.T22), web page ranking
// (M7.T03), memory decide/snapshot/review (M8.T02/T03), and document search — attachment excerpts (M6.T02), project
// file vectors and project retrieval (M8.T04/T05) through `DocumentEmbedding`. Missing the last one left in-app
// document and project search keyword-only while every bench (which passes an embedder itself) was green.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation

public enum AppRetrievalWiring {
    /// The embedder over the helper's `embed` slot and an optional `rerank` slot (`HelperEmbedder` in the app).
    public typealias MakeEmbedder = @Sendable (_ embed: @escaping @Sendable () -> ModelSlot?,
                                               _ rerank: @escaping @Sendable () -> ModelSlot?) -> HelperEmbedder

    /// The app's helper embedder factory for its engine (nil: no XPC helper, e.g. `-UseScriptedEngine`).
    public static func helperFactory(for engine: any EngineService) -> MakeEmbedder? {
        if let s = engine as? EngineSupervisorClient { return { HelperEmbedder(supervisor: s, embedSlot: $0, rerankSlot: $1) } }
        if let c = engine as? EngineClient { return { HelperEmbedder(engine: c, embedSlot: $0, rerankSlot: $1) } }
        return nil
    }

    /// Attaches the embedders. `make == nil` installs keyword-only search (no helper to embed with).
    public static func attach(database: AppDatabase, make: MakeEmbedder?, embed: @escaping @Sendable () -> ModelSlot?,
                              rerank: @escaping @Sendable () -> ModelSlot?, routeEmbedding: DeferredRouteEmbedding,
                              decisionModel: (any MemoryDecisionModel)?) {
        guard let make else {
            SemanticSearch.shared = SemanticSearch(database: database, embedder: nil)  // retrieval-wiring: no helper
            return
        }
        SemanticSearch.shared = SemanticSearch(database: database, embedder: make(embed, rerank))
        routeEmbedding.set(make(embed, { nil }))
        WebSearchTools.useEmbedder(make(embed, rerank))  // M7.T03: hybrid + T2+ rerank
        MemoryRuntime.for(database).attach(embedder: make(embed, { nil }), model: decisionModel)
        DocumentEmbedding.for(database).attach(make(embed, rerank))  // M6.T02 excerpts, M8.T04/T05 projects (T2+ rerank)
    }
}
