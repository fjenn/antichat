// Ported from mem0ai/mem0@26cdefb46600c0fa5953c4b5ee5003c125539fc4:mem0/configs/prompts.py (DEFAULT_UPDATE_MEMORY_PROMPT
// `:176`, events ADD/UPDATE/DELETE/NONE `:182-185`, Apache-2.0; P-media-01): the decision scheme and its JSON shape.
// The prompt wording is ours and shorter (one new fact against ≤ 5 neighbours, not a whole memory list).
// M8.T02 step 2 (R-242 AC3): a `save` first finds the k = 5 nearest active items of the same scope (any topic) by
// cosine on their stored vectors. top ≥ `updateCosine` → UPDATE that item without a model call; any neighbour ≥
// `askCosine` → the chat model decides (temperature 0, JSON); otherwise ADD. No embedder (pack removed) → FTS bm25
// neighbours stand in and the model decides when there are any (architecture §7.1 fail-open).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

/// Thresholds (tuned once on fixtures/memory/paraphrase-100 + distinct-20; recorded in the M8.T02 commit).
public struct MemoryConfig: Sendable, Equatable {
    public var updateCosine: Float = 0.92
    public var askCosine: Float = 0.60
    public var neighbours = 5
    public static let `default` = MemoryConfig()
    public init() {}
}

public enum MemoryDecision: Sendable, Equatable {
    case add
    case update(id: String, text: String)
    case delete(id: String)
    case none(id: String?)
}

/// The model call of the ambiguous band (Harness implements it on the chat engine; tests script it).
public protocol MemoryDecisionModel: Sendable {
    /// Raw model output for `prompt` (JSON expected); nil on failure.
    func complete(system: String, user: String) async -> String?
}

public struct MemoryUpdateDecider: Sendable {
    public let store: MemoryStore
    public let embedder: (any Embedder)?
    public let model: (any MemoryDecisionModel)?
    public var config: MemoryConfig

    public init(store: MemoryStore, embedder: (any Embedder)?, model: (any MemoryDecisionModel)?, config: MemoryConfig = .default) {
        self.store = store
        self.embedder = embedder
        self.model = model
        self.config = config
    }

    public struct Neighbour: Sendable, Equatable {
        public var item: MemoryItem
        public var cosine: Float?
    }

    public struct Outcome: Sendable, Equatable {
        public var decision: MemoryDecision
        /// The new fact's document vector (stored with the item so later saves compare against it).
        public var vector: [Float]?
        public var neighbours: [Neighbour]
        public var usedModel: Bool
        /// The model was asked and gave nothing usable (the decision then falls back to ADD). The background review
        /// reads this as "unsure".
        public var modelFailed = false
    }

    public func decide(new text: String, scope: MemoryScope, projectID: String?) async -> Outcome {
        let candidates = ((try? store.active(scope: scope, projectID: projectID)) ?? []).map(\.item)
        var vector: [Float]?
        if let embedder, let v = try? await embedder.embed([text], kind: .document).first, v.count == VecLoader.dimensions {
            vector = v
        }
        guard !candidates.isEmpty else { return Outcome(decision: .add, vector: vector, neighbours: [], usedModel: false) }
        var neighbours: [Neighbour] = []
        if let vector, let stored = try? store.vectors(candidates.map(\.id)), !stored.isEmpty {
            neighbours = candidates.compactMap { c in stored[c.id].map { Neighbour(item: c, cosine: Self.cosine(vector, $0)) } }
                .sorted { ($0.cosine ?? 0) > ($1.cosine ?? 0) }
            neighbours = Array(neighbours.prefix(config.neighbours))
            if let top = neighbours.first, let c = top.cosine, c >= config.updateCosine {
                return Outcome(decision: .update(id: top.item.id, text: text), vector: vector, neighbours: neighbours, usedModel: false)
            }
            neighbours = neighbours.filter { ($0.cosine ?? 0) >= config.askCosine }
        } else {
            neighbours = ftsNeighbours(text, among: candidates).map { Neighbour(item: $0, cosine: nil) }
        }
        guard !neighbours.isEmpty, let model else { return Outcome(decision: .add, vector: vector, neighbours: neighbours, usedModel: false) }
        let raw = await model.complete(system: Self.systemPrompt, user: Self.userPrompt(new: text, neighbours: neighbours.map(\.item)))
        let decision = raw.flatMap { Self.parse($0, known: Set(neighbours.map(\.item.id)), new: text) }
        return Outcome(decision: decision ?? .add, vector: vector, neighbours: neighbours, usedModel: true, modelFailed: decision == nil)
    }

    func ftsNeighbours(_ text: String, among candidates: [MemoryItem]) -> [MemoryItem] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: text) else { return [] }
        let ids = (try? store.database.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.source_id FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid
                WHERE chunk_fts MATCH ? AND c.source = 'memory' ORDER BY bm25(chunk_fts) LIMIT ?
                """, arguments: [pattern, config.neighbours])
        }) ?? []
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    // MARK: Prompt (mem0 scheme)

    public static let systemPrompt = """
        You manage a list of facts about the user. Compare one new fact with the existing facts and choose one event:
        ADD: the new fact is new information not covered by any existing fact.
        UPDATE: the new fact is about the same thing as one existing fact (same meaning said differently, or newer or more detailed information). Give that fact's id and the merged text.
        DELETE: the new fact says an existing fact is no longer true and states nothing new. Give that fact's id.
        NONE: the new fact is already fully covered by one existing fact. Give that fact's id.
        Answer with JSON only: {"event":"ADD|UPDATE|DELETE|NONE","id":"<existing id or null>","text":"<merged text>"}
        """

    public static func userPrompt(new: String, neighbours: [MemoryItem]) -> String {
        let list = neighbours.map { "{\"id\":\"\($0.id)\",\"text\":\(jsonString($0.text))}" }.joined(separator: ",\n")
        return "Existing facts:\n[\(list)]\n\nNew fact: \(jsonString(new))\n\nJSON:"
    }

    static func jsonString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s], options: [])).flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// The first JSON object in `raw`; ids must be one of the neighbours (anything else → nil = ADD).
    public static func parse(_ raw: String, known: Set<String>, new: String) -> MemoryDecision? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let event = (obj["event"] as? String)?.uppercased() else { return nil }
        let id = (obj["id"] as? String).flatMap { known.contains($0) ? $0 : nil }
        let text = (obj["text"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        switch event {
        case "ADD": return .add
        case "UPDATE": return id.map { .update(id: $0, text: String((text ?? new).prefix(MemoryStore.maxText))) }
        case "DELETE": return id.map { .delete(id: $0) }
        case "NONE": return .none(id: id)
        default: return nil
        }
    }
}
