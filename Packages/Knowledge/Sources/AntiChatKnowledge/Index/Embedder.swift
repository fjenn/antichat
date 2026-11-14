// M2.T16: what the index needs from the helper's search models. Harness's EngineClient conforms (XPC EmbedRequest /
// RerankRequest); tests use a deterministic fake. `nil` from the provider = no embed model installed or loaded, and
// search falls back to FTS only with no visible error (R-244 AC3, R-295).
import AntiChatEngineProtocol
import Foundation

public protocol Embedder: Sendable {
    func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]]
    /// Scores per document (higher = better); nil when no reranker is assigned on this tier (T0/T1).
    func rerank(query: String, documents: [String]) async throws -> [Float]?
}
