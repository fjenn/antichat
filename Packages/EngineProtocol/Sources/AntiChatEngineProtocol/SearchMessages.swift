// M2.T16 (R-244, R-295): the helper's search models over XPC. `EmbedRequest` turns texts into unit vectors with the
// `embed` model (Qwen3-Embedding-0.6B, 1024-d); `RerankRequest` scores documents against a query with `rerank`
// (T2+). Both are answered by one `ServerMessage.Body.search(SearchReply)` (no stream). The scheduler keeps the
// models resident 2 min after the last use (KeepAlivePolicy.embedSeconds).
import AntiChatFoundation
import Foundation

public struct EmbedRequest: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case query, document }
    public var requestID: UUID
    public var modelSlot: ModelSlot
    public var texts: [String]
    /// Qwen3-Embedding wants an instruction prefix on queries only.
    public var kind: Kind
    public init(requestID: UUID = UUID(), modelSlot: ModelSlot, texts: [String], kind: Kind) {
        self.requestID = requestID
        self.modelSlot = modelSlot
        self.texts = texts
        self.kind = kind
    }
}

public struct RerankRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var modelSlot: ModelSlot
    public var query: String
    public var documents: [String]
    public init(requestID: UUID = UUID(), modelSlot: ModelSlot, query: String, documents: [String]) {
        self.requestID = requestID
        self.modelSlot = modelSlot
        self.query = query
        self.documents = documents
    }
}

public struct SearchReply: Codable, Sendable, Hashable {
    /// One vector per text (EmbedRequest).
    public var vectors: [[Float]]?
    /// One score per document, higher = more relevant (RerankRequest).
    public var scores: [Float]?
    public var error: AntiChatError?
    /// M6.T02: one count per text of a CountTokensRequest; `tokensEstimated` = no tokenizer, ⌈chars / 4⌉.
    public var tokens: [Int]?
    public var tokensEstimated: Bool?
    public init(vectors: [[Float]]? = nil, scores: [Float]? = nil, error: AntiChatError? = nil, tokens: [Int]? = nil,
                tokensEstimated: Bool? = nil) {
        self.vectors = vectors
        self.scores = scores
        self.error = error
        self.tokens = tokens
        self.tokensEstimated = tokensEstimated
    }
}
