// M8.T03 step 6–7 (R-246 AC1/AC2), owner 2026-11-16: the background memory review keeps memory up to date by itself
// and asks only when it is unsure. It runs only when every gate holds (review enabled, memory On, AC power, not Low
// Power Mode, idle ≥ 300 s, no turn or media job running, thermal ≤ fair, ≥ 6 h since the last run), reads the user
// turns of non-incognito, memory-enabled, non-Evil (unless allowed) chats updated since the last run and asks the
// chat model for ≤ 5 facts, each with a confidence.
//   certain (stated outright, lasting) and not touching an existing memory → saved at once through MemoryStore.insert
//     (origin review, one memory_event; listed and removable in Settings) plus a `memory_suggestion` row 'saved';
//   anything else → a `memory_suggestion` row 'pending' for the user's Save / Dismiss (pill, Personalization):
//     confidence unsure or missing, or the fact updates / contradicts an existing memory, or that comparison failed.
// Output that does not parse yields no facts, so nothing is saved. A fact that is already stored, or that the review
// handled before (any `memory_suggestion` row with the same normalised text: pending, saved or dismissed), is skipped,
// so a dismissed or deleted fact is not brought back. Power, idle, thermal and tier come in through protocols
// (Knowledge never imports Platform). Osaurus memory v2 auto-distillation is not used (ours keeps the unsure path).
import AntiChatStorage
import Foundation
import GRDB

public protocol PowerSource: Sendable { var onACPower: Bool { get }; var lowPowerMode: Bool { get } }
public protocol IdleClock: Sendable { var idleSeconds: Double { get } }
public protocol ThermalSource: Sendable { var isFairOrBetter: Bool { get } }

public struct MemorySuggestion: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memory_suggestion"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public enum State: String, Codable, Sendable { case pending, saved, dismissed }
    public var id: String
    public var text: String
    public var topic: String
    public var scope: MemoryScope
    public var projectID: String?
    public var sensitiveCategory: SensitiveCategory?
    public var sourceChatIDsJSON: String
    public var state: State
    public var createdAt: Date
    public var decidedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, text, topic, scope, state, projectID = "project_id", sensitiveCategory = "sensitive_category",
             sourceChatIDsJSON = "source_chat_ids_json", createdAt = "created_at", decidedAt = "decided_at"
    }
}

public struct MemoryReviewService: Sendable {
    public static let idleThreshold: Double = 300
    public static let minInterval: TimeInterval = 6 * 3600
    public static let maxFacts = 5
    public static let minChars = 8
    /// Default of "Keep memory up to date automatically": on for T2–T4, off for T0–T1 (registered at launch by the app).
    public static func defaultEnabled(tier: String) -> Bool { !["T0", "T1"].contains(tier.uppercased()) }

    public struct Gates: Sendable {
        public var enabled: Bool
        public var policy: MemoryPolicy
        public var power: any PowerSource
        public var idle: any IdleClock
        public var thermal: any ThermalSource
        public var busy: @Sendable () -> Bool
        public init(enabled: Bool, policy: MemoryPolicy, power: any PowerSource, idle: any IdleClock, thermal: any ThermalSource,
                    busy: @escaping @Sendable () -> Bool) {
            self.enabled = enabled; self.policy = policy; self.power = power; self.idle = idle; self.thermal = thermal; self.busy = busy
        }
    }

    public enum Skip: String, Sendable, Equatable { case disabled, memoryNotOn, battery, lowPower, notIdle, busy, thermal, tooSoon }

    public let store: MemoryStore
    public let model: (any MemoryDecisionModel)?
    public let embedder: (any Embedder)?
    public var config: MemoryConfig = .default

    public init(store: MemoryStore, model: (any MemoryDecisionModel)?, embedder: (any Embedder)?) {
        self.store = store
        self.model = model
        self.embedder = embedder
    }

    /// Why a run would not start now (nil = run).
    public func skipReason(_ g: Gates, lastRun: Date?) -> Skip? {
        if !g.enabled { return .disabled }
        if g.policy.mode != .on { return .memoryNotOn }
        if !g.power.onACPower { return .battery }
        if g.power.lowPowerMode { return .lowPower }
        if g.idle.idleSeconds < Self.idleThreshold { return .notIdle }
        if g.busy() { return .busy }
        if !g.thermal.isFairOrBetter { return .thermal }
        if let lastRun, store.now().timeIntervalSince(lastRun) < Self.minInterval { return .tooSoon }
        return nil
    }

    /// One review: returns the rows it wrote, `saved` (stored by itself) and `pending` (for the user to choose);
    /// empty when gated or nothing new.
    @discardableResult
    public func run(_ g: Gates, lastRun: Date?) async throws -> [MemorySuggestion] {
        guard skipReason(g, lastRun: lastRun) == nil, let model else { return [] }
        let (texts, chats) = try userTurns(since: lastRun ?? .distantPast, allowEvil: g.policy.useInEvil)
        guard !texts.isEmpty else { return [] }
        let raw = await model.complete(system: Self.systemPrompt, user: "User messages:\n" + texts.suffix(40).map { "- \($0)" }.joined(separator: "\n") + "\n\nJSON:")
        let facts = Self.parse(raw ?? "")
        let decider = MemoryUpdateDecider(store: store, embedder: embedder, model: model, config: config)
        var handled = Set(try store.database.read { try String.fetchAll($0, sql: "SELECT text FROM memory_suggestion") }.map(MemoryStore.normalized))
        var written: [MemorySuggestion] = []
        let chatsJSON = String(data: try JSONEncoder().encode(chats), encoding: .utf8) ?? "[]"
        for f in facts.prefix(Self.maxFacts) {
            if f.sensitive != nil, !g.policy.includeSensitive { continue }
            guard handled.insert(MemoryStore.normalized(f.text)).inserted else { continue }
            if try await isKnown(f.text, active: try store.active().map(\.item)) { continue }
            var s = MemorySuggestion(id: StorageID.make(now: store.now()), text: f.text, topic: f.topic, scope: .global,
                                     sensitiveCategory: f.sensitive, sourceChatIDsJSON: chatsJSON, state: .pending, createdAt: store.now())
            if f.certain {
                let outcome = await decider.decide(new: f.text, scope: .global, projectID: nil)
                if case .none = outcome.decision { continue }  // an existing memory already covers it
                if outcome.decision == .add, !outcome.modelFailed {
                    try store.insert(topic: f.topic, key: MemoryToolExecutor.key(from: f.text), text: f.text, sensitive: f.sensitive,
                                     origin: .review, vector: outcome.vector)
                    s.state = .saved
                    s.decidedAt = store.now()
                }  // else it would change or replace an existing memory, or the comparison failed: the user chooses
            }
            try store.database.write { [s] in try s.insert($0) }
            written.append(s)
        }
        return written
    }

    public func pending() throws -> [MemorySuggestion] {
        try store.database.read { try MemorySuggestion.filter(Column("state") == "pending").order(Column("created_at")).fetchAll($0) }
    }

    /// The user's Save tap on a pending suggestion.
    @discardableResult
    public func save(_ id: String) throws -> MemoryItem? {
        guard var s = try store.database.read({ try MemorySuggestion.fetchOne($0, key: id) }), s.state == .pending else { return nil }
        let (item, _) = try store.insert(topic: String(s.topic.prefix(MemoryStore.maxTopic)), key: MemoryToolExecutor.key(from: s.text),
                                         text: s.text, sensitive: s.sensitiveCategory, origin: .review)
        s.state = .saved
        s.decidedAt = store.now()
        try store.database.write { try s.update($0) }
        return item
    }

    public func dismiss(_ id: String) throws {
        try store.database.write { db in
            try db.execute(sql: "UPDATE memory_suggestion SET state = 'dismissed', decided_at = ? WHERE id = ? AND state = 'pending'",
                           arguments: [store.now().timeIntervalSince1970, id])
        }
    }

    // MARK: Internals

    /// Review fix (M8.T16): chats of a project with project-only memory are left out (their facts never become
    /// global suggestions).
    func userTurns(since: Date, allowEvil: Bool) throws -> ([String], [String]) {
        try store.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS chat, p.body AS body FROM message m JOIN chat c ON c.id = m.chat_id
                JOIN message_part p ON p.message_id = m.id AND p.kind = 'text'
                WHERE m.role = 'user' AND c.memory_enabled = 1 AND (c.mode = 'normal' OR ?) AND c.updated_at >= ?
                  AND (c.project_id IS NULL OR c.project_id NOT IN (SELECT id FROM project WHERE memory_mode = 'project'))
                ORDER BY m.created_at
                """, arguments: [allowEvil, since.timeIntervalSince1970])
            return (rows.map { $0["body"] as String }, Array(Set(rows.map { $0["chat"] as String })).sorted())
        }
    }

    func isKnown(_ text: String, active: [MemoryItem]) async throws -> Bool {
        let wanted = MemoryStore.normalized(text)
        if active.contains(where: { MemoryStore.normalized($0.text) == wanted }) { return true }
        guard let embedder, let v = try? await embedder.embed([text], kind: .document).first else { return false }
        let vectors = try store.vectors(active.map(\.id))
        return vectors.values.contains { MemoryUpdateDecider.cosine(v, $0) >= config.updateCosine }
    }

    /// `certain` only when the model said so; a missing or unknown confidence is unsure.
    struct Fact: Equatable { var topic: String; var text: String; var sensitive: SensitiveCategory?; var certain = false }

    static let systemPrompt = """
        Read the user's messages and list up to 5 lasting facts about the user that would help in future chats \
        (name, job, family, lasting preferences, ongoing projects, how they like answers). Skip one-off requests and \
        anything about other people only. \
        Set confidence to "certain" only when the user stated the fact outright and it will stay true; use "unsure" \
        when you inferred it, when it may be temporary, or when the messages disagree. \
        Tag facts about health, sexuality, religion, politics or money with that category.
        Answer with JSON only: [{"topic":"<short topic>","text":"<fact>","confidence":"certain|unsure","sensitive_category":"none|health|sexuality|religion|politics|finances"}]
        """

    static func parse(_ raw: String) -> [Fact] {
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e,
              let arr = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= minChars,
                  text.count <= MemoryStore.maxText else { return nil }
            let topic = ((o["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "General"
            let confidence = (o["confidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return Fact(topic: String(topic.prefix(MemoryStore.maxTopic)), text: text,
                        sensitive: (o["sensitive_category"] as? String).flatMap(SensitiveCategory.init(rawValue:)),
                        certain: confidence == "certain")
        }
    }
}
