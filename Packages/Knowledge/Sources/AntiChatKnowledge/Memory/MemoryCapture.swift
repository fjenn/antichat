// Per-turn memory capture, step 2 (owner 2026-11-17). The chat model does not reliably call the `memory` tool on its
// own (it answered "I have noted your preference" and saved nothing), and the idle review (MemoryReviewService) runs
// hours later and not on every Mac. So after a reply is delivered, when MemoryCaptureGate fires on the user's
// message, one short extraction call on the chat model lists what the message states about the user, and each fact is
// handled exactly as the review handles it:
//   certain and new (the decider says ADD without a failed comparison) → MemoryStore.insert (origin review, one
//     memory_event; the caller shows "Memory updated ▸ Undo" on the reply) plus a `memory_suggestion` row 'saved';
//   unsure, or it would change / contradict an existing memory, or that comparison failed → a 'pending' row for the
//     user's Save / Dismiss (pill, Personalization);
//   already stored (same normalised text, or a near-identical vector), handled before (any `memory_suggestion` row
//     with that text: a dismissed or deleted fact is not brought back), sensitive with "Include sensitive topics"
//     off, or output that does not parse → nothing.
// In a project with project-only memory a certain fact is saved to that project and nothing is suggested (the
// suggestion list is global). A cancelled task writes nothing: cancellation is checked before every write, and the
// writes themselves are synchronous.
// Cost: only a gated message costs anything: one call of ≤ `budget.maxTokens` output tokens and ≤ `budget.timeout`,
// plus the decider's call under the same budget when a similar memory exists.
import AntiChatStorage
import Foundation
import GRDB

/// Output and time limits of one memory side call.
public struct MemoryCallBudget: Sendable, Equatable {
    public var maxTokens: Int
    public var timeout: Duration
    public init(maxTokens: Int, timeout: Duration) {
        self.maxTokens = maxTokens
        self.timeout = timeout
    }
}

/// A model that takes a budget per call (the engine-backed one); any other answers under its own default.
public protocol BudgetedMemoryModel: MemoryDecisionModel {
    func complete(system: String, user: String, budget: MemoryCallBudget) async -> String?
}

/// `base` under a fixed budget (the decider's comparison call during a capture).
struct BudgetedModel: MemoryDecisionModel {
    let base: any MemoryDecisionModel
    let budget: MemoryCallBudget
    func complete(system: String, user: String) async -> String? {
        if let b = base as? any BudgetedMemoryModel { return await b.complete(system: system, user: user, budget: budget) }
        return await base.complete(system: system, user: user)
    }
}

public struct MemoryCapture: Sendable {
    public static let budget = MemoryCallBudget(maxTokens: 160, timeout: .seconds(10))
    public static let maxFacts = 2

    public struct Outcome: Sendable, Equatable {
        /// The extraction call was made (false: gated out, memory not On, or no model).
        public var called = false
        /// Events of the facts saved by themselves (the reply's "Memory updated" line).
        public var eventIDs: [String] = []
        public var saved: [MemoryItem] = []
        public var pending: [MemorySuggestion] = []
    }

    public let store: MemoryStore
    public let model: (any MemoryDecisionModel)?
    public let embedder: (any Embedder)?
    public var config: MemoryConfig = .default

    public init(store: MemoryStore, model: (any MemoryDecisionModel)?, embedder: (any Embedder)?) {
        self.store = store
        self.model = model
        self.embedder = embedder
    }

    /// One capture for the user message `userText` of `chatID`. `projectID`: the chat's project when its memory is
    /// project-only.
    public func run(userText: String, chatID: String, userMessageID: String? = nil, policy: MemoryPolicy,
                    projectID: String? = nil) async -> Outcome {
        var out = Outcome()
        guard policy.mode == .on, let model, let gate = MemoryCaptureGate.evaluate(userText) else { return out }
        out.called = true
        let bounded = BudgetedModel(base: model, budget: Self.budget)
        let raw = await bounded.complete(system: Self.systemPrompt, user: "User message:\n\(gate.excerpt)\n\nJSON:")
        guard !Task.isCancelled, let raw else { return out }
        let review = MemoryReviewService(store: store, model: bounded, embedder: embedder)
        let decider = MemoryUpdateDecider(store: store, embedder: embedder, model: bounded, config: config)
        let scope: MemoryScope = projectID == nil ? .global : .project
        do {
            var handled = Set(try store.database.read { try String.fetchAll($0, sql: "SELECT text FROM memory_suggestion") }
                .map(MemoryStore.normalized))
            let chatsJSON = String(data: try JSONEncoder().encode([chatID]), encoding: .utf8) ?? "[]"
            for f in MemoryReviewService.parse(raw).prefix(Self.maxFacts) {
                if f.sensitive != nil, !policy.includeSensitive { continue }
                guard handled.insert(MemoryStore.normalized(f.text)).inserted else { continue }
                if try store.duplicate(of: f.text, projectID: projectID) != nil { continue }
                if try await review.isKnown(f.text, active: try store.active(scope: scope, projectID: projectID).map(\.item)) { continue }
                var s = MemorySuggestion(id: StorageID.make(now: store.now()), text: f.text, topic: f.topic, scope: scope,
                                         projectID: projectID, sensitiveCategory: f.sensitive, sourceChatIDsJSON: chatsJSON,
                                         state: .pending, createdAt: store.now())
                var item: (MemoryItem, MemoryEvent)?
                if f.certain {
                    let outcome = await decider.decide(new: f.text, scope: scope, projectID: projectID)
                    if case .none = outcome.decision { continue }  // an existing memory already covers it
                    guard !Task.isCancelled else { return out }
                    if outcome.decision == .add, !outcome.modelFailed {
                        item = try store.insert(topic: f.topic, scope: scope, projectID: projectID, key: MemoryToolExecutor.key(from: f.text),
                                                text: f.text, sensitive: f.sensitive, origin: .review, sourceChatID: chatID,
                                                sourceMessageID: userMessageID, vector: outcome.vector)
                        s.state = .saved
                        s.decidedAt = store.now()
                    }
                }
                guard !Task.isCancelled || item != nil else { return out }
                if item == nil, projectID != nil { continue }  // suggestions are global: none from project-only memory
                try store.database.write { [s] in try s.insert($0) }
                if let item {
                    out.saved.append(item.0)
                    out.eventIDs.append(item.1.id)
                } else {
                    out.pending.append(s)
                }
            }
        } catch {
            return out  // a failed read or write leaves what was written before it
        }
        return out
    }

    /// The review's prompt for one message, as short as it gets (every tier runs it); same JSON shape
    /// (MemoryReviewService.parse).
    static let systemPrompt = """
        List what the user's message states about the user that will still matter in later chats: name, job, family, \
        lasting preferences, ongoing projects, how they want answers. At most 2 facts, each a short sentence that \
        stands alone. Skip one-off requests, questions and things about other people only; nothing lasting → []. \
        confidence is "certain" only when the user stated it outright and it will stay true, else "unsure". \
        Tag facts about health, sexuality, religion, politics or money with that category.
        Answer with JSON only: [{"topic":"<short topic>","text":"<fact>","confidence":"certain|unsure","sensitive_category":"none|health|sexuality|religion|politics|finances"}]
        """
}
