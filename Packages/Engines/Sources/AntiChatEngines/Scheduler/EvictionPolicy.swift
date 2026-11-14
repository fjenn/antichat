// M2.T12 step 2 + step 6 (R-206 AC1, NFR-R4; blueprint E §E.2.7). Ported design from ollama/ollama@04088e7
// server/sched.go (MIT) — `processPending` fit-or-evict loop and `findRunnerToUnload` (idle runner first, then by
// last use) — with AntiChat's rules: "fits" = Σ effective footprints ≤ B (never live free memory, which other apps
// share on unified memory); victims are idle models by E.2.7 priority, then LRU; an active lease is never a victim;
// each engine holds at most `capacity[engine]` models (MLX one container, llama one single-model server, A-M1-T12a),
// so a same-engine model is replaced (after its leases drain). With "Allow loads above the memory budget" a load
// that cannot fit proceeds after evicting every idle model (NFR-R5).
import AntiChatEngineProtocol
import Foundation

public struct ResidentEntry: Sendable, Equatable {
    public var slot: ModelSlot
    public var role: ResidencyRole
    /// max(measured, catalog), bytes.
    public var bytes: UInt64
    public var refCount: Int
    /// Scheduler clock seconds of the last use (lease release or load).
    public var lastUsed: Double
    public var key: String { slot.key }

    public init(slot: ModelSlot, role: ResidencyRole, bytes: UInt64, refCount: Int = 0, lastUsed: Double = 0) {
        self.slot = slot; self.role = role; self.bytes = bytes; self.refCount = refCount; self.lastUsed = lastUsed
    }
}

public enum EvictionPolicy {
    public static let defaultCapacity: [EngineKind: Int] = [.mlx: 1, .llama: 1, .scripted: 1]

    public enum PlanError: Error, Equatable, Sendable {
        /// Does not fit even after evicting every idle model (`model.notEnoughMemory`).
        case doesNotFit(need: UInt64, budget: UInt64)
    }

    public struct Plan: Sendable, Equatable {
        /// In unload order. `mustWait` victims hold a lease (same-engine replacement): unload after it drains.
        public var victims: [String]
        public var overBudget: Bool
    }

    /// The role a chat entry plays now: every chat model but the most recently used one is the "second variant".
    public static func effectiveRole(_ e: ResidentEntry, in entries: [ResidentEntry]) -> ResidencyRole {
        guard e.role == .chat else { return e.role }
        let newest = entries.filter { $0.role == .chat }.max { $0.lastUsed < $1.lastUsed }
        return newest?.key == e.key ? .chat : .secondChat
    }

    /// Victims, lowest priority first: E.2.7 rank, then least recently used.
    public static func order(_ entries: [ResidentEntry]) -> [ResidentEntry] {
        entries.sorted {
            let a = effectiveRole($0, in: entries).evictionRank, b = effectiveRole($1, in: entries).evictionRank
            return a != b ? a < b : ($0.lastUsed, $0.key) < ($1.lastUsed, $1.key)
        }
    }

    public static func plan(entries: [ResidentEntry], incoming: ModelSlot, incomingBytes: UInt64, budget: UInt64,
                            allowOverBudget: Bool, capacity: [EngineKind: Int] = defaultCapacity) -> Result<Plan, PlanError> {
        let others = entries.filter { $0.key != incoming.key }
        var victims: [String] = []
        // Engine capacity: the oldest same-engine models go first, whatever their role (replacement). It counts the
        // engine's containers (MLX one chat container, llama one server); the embedding / reranker / citation-check
        // models live in their own services (EmbeddingService, CiteCheckService) and only count against B.
        if let kind = capacityKind(incoming) {
            let cap = capacity[kind] ?? .max
            let sameEngine = order(others.filter { capacityKind($0.slot) == kind })
            if sameEngine.count >= cap { victims += sameEngine.prefix(sameEngine.count - cap + 1).map(\.key) }
        }
        guard budget > 0 else { return .success(Plan(victims: victims, overBudget: false)) }
        func used() -> UInt64 { others.filter { !victims.contains($0.key) }.reduce(0) { $0 + $1.bytes } }
        for e in order(others) where used() + incomingBytes > budget {
            guard !victims.contains(e.key), e.refCount == 0 else { continue }
            victims.append(e.key)
        }
        if used() + incomingBytes > budget {
            guard allowOverBudget else { return .failure(.doesNotFit(need: used() + incomingBytes, budget: budget)) }
            return .success(Plan(victims: victims, overBudget: true))
        }
        return .success(Plan(victims: victims, overBudget: false))
    }

    /// The engine container a slot occupies (nil = a service model outside the engine's container count).
    /// M7 bars (T1 search latency): the MLX `embed` slot counted as the one MLX container, so on T0–T2 every web step's
    /// page ranking (and the pre-router) unloaded the chat model and the next step reloaded it with an empty prefix
    /// cache (0 cached tokens at T1 vs 2.4K at T4, where the warm second variant gives MLX two slots).
    public static func capacityKind(_ slot: ModelSlot) -> EngineKind? {
        EmbeddingService.handles(slot) || CiteCheckService.handles(slot) ? nil : slot.engine
    }

    /// NFR-R4: may this role stay resident without a running job on this tier? (T0–T2: chat + embed + voice only.)
    public static func mayStayResident(_ role: ResidencyRole, lowTier: Bool) -> Bool { !(lowTier && role.isJobModel) }
}
