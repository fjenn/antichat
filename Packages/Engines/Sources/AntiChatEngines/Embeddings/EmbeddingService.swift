// M2.T16 step 3 (R-244, R-295; P-media-15): the helper's embedding model. Qwen3-Embedding-0.6B (MLX, 1024-d,
// last-token pooling, L2-normalised) loaded with mlx-swift-lm f5b0677 `MLXEmbedders` from its install view. Residency
// goes through the ModelScheduler (role `embed`, 2 min idle unload): EngineRuntime routes `embed*` / `rerank*` slots
// here. Batches of 32 texts. Queries carry the model's instruction prefix (Qwen3-Embedding model card); documents
// are embedded as-is.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXRerankers

public actor EmbeddingService {
    public static let batchSize = 32
    /// Qwen3-Embedding query instruction (model card "Instruct: …\nQuery:"); documents get none.
    public static let queryInstruction = "Instruct: Given a search query, retrieve relevant passages from past chats\nQuery:"
    /// Tokens per text (the indexer cuts chunks of ≤ 512 tokens; this is the guard).
    public static let maxTokens = 512

    private var containers: [String: EmbedderModelContainer] = [:]
    private var rerankers: [String: RerankerContainer] = [:]

    public init() {}

    /// The slots this service owns (catalog roles `embed` / `rerank`, plus their fallbacks).
    public static func handles(_ slot: ModelSlot) -> Bool {
        slot.engine == .mlx && (slot.key.hasPrefix("embed") || slot.key.hasPrefix("rerank"))
    }

    // MARK: Residency (called by EngineRuntime for the scheduler only)

    public func load(_ slot: ModelSlot) async throws -> Double {
        if containers[slot.key] != nil || rerankers[slot.key] != nil { return 0 }
        let url = URL(fileURLWithPath: slot.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
            throw AntiChatError(.modelMissing, detail: slot.key)
        }
        let start = ContinuousClock.now
        do {
            if slot.key.hasPrefix("rerank") {
                rerankers[slot.key] = try await RerankerModelFactory.shared.loadContainer(
                    from: url, using: TransformersTokenizerLoader(), allowUnverifiedModel: true)
            } else {
                containers[slot.key] = try await EmbedderModelFactory.shared.loadContainer(
                    from: url, using: TransformersTokenizerLoader())
            }
        } catch {
            throw AntiChatError(.modelCorrupt, detail: "\(slot.key): \(error)")
        }
        return EngineTime.secs(ContinuousClock.now - start)
    }

    public func unload(_ key: String) {
        containers[key] = nil
        rerankers[key] = nil
        Memory.clearCache()
    }

    public func holds(_ key: String) -> Bool { containers[key] != nil || rerankers[key] != nil }

    // MARK: Work

    /// Unit vectors for `texts`, in order.
    public func embed(_ texts: [String], kind: EmbedRequest.Kind, key: String) async throws -> [[Float]] {
        guard let container = containers[key] else { throw AntiChatError(.modelMissing, detail: key) }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var i = 0
        while i < texts.count {
            let batch = Array(texts[i..<min(i + Self.batchSize, texts.count)])
                .map { kind == .query ? "\(Self.queryInstruction)\($0)" : $0 }
            let vectors = await container.perform { context -> [[Float]] in
                let ids = batch.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(Self.maxTokens)) }
                let pad = context.tokenizer.eosTokenId ?? 0
                let longest = ids.reduce(1) { max($0, $1.count) }
                let padded = stacked(ids.map { MLXArray($0 + Array(repeating: pad, count: longest - $0.count)) })
                let mask = stacked(ids.map { MLXArray(Array(repeating: true, count: $0.count)
                                                      + Array(repeating: false, count: longest - $0.count)) })
                let result = context.pooling(
                    context.model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask),
                    mask: mask, normalize: true, applyLayerNorm: false)
                result.eval()
                return result.map { $0.asArray(Float.self) }
            }
            out += vectors.map(Self.unit)  // vec0 L2 distance ranks like cosine only on unit vectors
            i += Self.batchSize
        }
        return out
    }

    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// Relevance score per document (higher = better), in the documents' order.
    public func rerank(query: String, documents: [String], key: String) async throws -> [Float] {
        guard let container = rerankers[key] else { throw AntiChatError(.modelMissing, detail: key) }
        let response = try await container.rerank(query: query, documents: documents)
        var scores = [Float](repeating: -.infinity, count: documents.count)
        for r in response.results where r.index < scores.count { scores[r.index] = Float(r.score) }
        return scores
    }
}
