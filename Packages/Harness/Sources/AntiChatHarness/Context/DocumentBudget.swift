// M6.T02 step 1 (R-270 AC1, exactly): whole document or excerpts. With `tokens` counted by the active model's
// tokenizer (`CountTokens`), `reservedAnswer = min(2048, 0.25 × context_tokens)`,
// `freeContext = context_tokens − tokens(system + memory + tools) − tokens(history) − reservedAnswer`:
//   inline iff tokens ≤ min(0.5 × freeContext, prefill_tps × 20)
//   fitsContext = tokens ≤ 0.5 × freeContext · fitsTime = tokens ≤ prefill_tps × 20 · estimateSeconds = ⌈tokens / prefill_tps⌉
// Several attachments are decided in attach order against what the earlier inline ones left (context and time).
// `[Read whole file]` is offered only when `fitsContext && !fitsTime` (R-270 AC2).
import Foundation

public enum DocumentBudget {
    public struct Model: Sendable, Equatable, Codable {
        /// The effective context (`context_default` unless the scheduler raised it; A-M6-06 `context_tokens`).
        public var contextTokens: Int
        public var prefillTPS: Double
        public init(contextTokens: Int, prefillTPS: Double) {
            self.contextTokens = contextTokens; self.prefillTPS = prefillTPS
        }
    }

    public struct ChatState: Sendable, Equatable {
        /// system + memory + tools.
        public var fixedTokens: Int
        public var historyTokens: Int
        public init(fixedTokens: Int, historyTokens: Int) { self.fixedTokens = fixedTokens; self.historyTokens = historyTokens }
    }

    public enum Mode: String, Sendable, Codable { case inline, excerpts }

    public struct Decision: Sendable, Equatable, Codable {
        public var mode: Mode
        public var fitsContext: Bool
        public var fitsTime: Bool
        public var estimateSeconds: Int
        /// R-270 AC2: the excerpt note offers `[Read whole file]`.
        public var offersReadWhole: Bool { fitsContext && !fitsTime }
    }

    public static func reservedAnswer(_ contextTokens: Int) -> Int { min(2048, Int((0.25 * Double(contextTokens)).rounded(.down))) }

    public static func freeContext(_ model: Model, _ chat: ChatState) -> Int {
        model.contextTokens - chat.fixedTokens - chat.historyTokens - reservedAnswer(model.contextTokens)
    }

    public static func decide(tokens: Int, model: Model, chat: ChatState, timeUsed: Int = 0) -> Decision {
        let free = Double(freeContext(model, chat))
        let fitsContext = Double(tokens) <= 0.5 * free
        let fitsTime = Double(tokens) <= model.prefillTPS * 20 - Double(timeUsed)
        let estimate = model.prefillTPS > 0 ? Int((Double(tokens) / model.prefillTPS).rounded(.up)) : Int.max
        return Decision(mode: fitsContext && fitsTime ? .inline : .excerpts, fitsContext: fitsContext, fitsTime: fitsTime,
                        estimateSeconds: estimate)
    }

    /// Attach order: each inline document joins the history (context) and uses prefill time for the next ones.
    /// `forceInline` (R-270 AC2 `[Read whole file]`): those indices go inline when they fit the context.
    public static func decideAll(tokens: [Int], model: Model, chat: ChatState, forceInline: Set<Int> = []) -> [Decision] {
        var state = chat
        var timeUsed = 0
        return tokens.enumerated().map { i, t in
            var d = decide(tokens: t, model: model, chat: state, timeUsed: timeUsed)
            if forceInline.contains(i), d.fitsContext { d.mode = .inline }
            if d.mode == .inline {
                state.historyTokens += t
                timeUsed += t
            }
            return d
        }
    }
}

/// `tier-budgets.json` (A-M6-06): per-tier evidence budgets; M6.T02 reads `files.retrieval_top_k` and `files.prefill_tps`.
public struct TierBudgets: Sendable, Decodable {
    public struct Files: Sendable, Decodable {
        public var retrievalTopK: [String: Int]
        public var prefillTPS: [String: Double]
        /// A-M6-T02a: the conservative rate per tier for a model key missing from `prefillTPS`.
        public var prefillTPSTierDefault: [String: Double]
        /// M6.T07: per-chat DuckDB `memory_limit` (MB) and the sheet profile block cap (tokens).
        public var duckDBMemoryMB: [String: Int] = [:]
        public var sheetProfileTokens: [String: Int] = [:]
        enum CodingKeys: String, CodingKey {
            case retrievalTopK = "retrieval_top_k", prefillTPS = "prefill_tps", prefillTPSTierDefault = "prefill_tps_tier_default"
            case duckDBMemoryMB = "duckdb_memory_mb", sheetProfileTokens = "sheet_profile_tokens"
        }
        public init(retrievalTopK: [String: Int], prefillTPS: [String: Double], prefillTPSTierDefault: [String: Double]) {
            self.retrievalTopK = retrievalTopK; self.prefillTPS = prefillTPS; self.prefillTPSTierDefault = prefillTPSTierDefault
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            retrievalTopK = try c.decode([String: Int].self, forKey: .retrievalTopK)
            prefillTPS = try c.decodeIfPresent([String: Double].self, forKey: .prefillTPS) ?? [:]
            prefillTPSTierDefault = try c.decodeIfPresent([String: Double].self, forKey: .prefillTPSTierDefault) ?? [:]
            duckDBMemoryMB = try c.decodeIfPresent([String: Int].self, forKey: .duckDBMemoryMB) ?? [:]
            sheetProfileTokens = try c.decodeIfPresent([String: Int].self, forKey: .sheetProfileTokens) ?? [:]
        }
    }
    /// M7.T01 step 0 (A-M7-04): blueprint B §B1.6 / §B4.6 / §B3.6 / §B2.6 rows, copied once; code reads them from here.
    public struct Search: Sendable, Decodable, Equatable {
        public var source: String
        public var queries: [String: Int], pages: [String: Int], evidenceTokens: [String: Int]
        public var reranker: [String: Bool], freeRaceBudgetS: [String: Double]
        /// M9.T05 (AT-254 T3): seconds after the page fetch starts to answer with the pages in by then (a tier without
        /// a cell waits for every page).
        public var fetchDeadlineS: [String: Double]?
        enum CodingKeys: String, CodingKey {
            case source, queries, pages, reranker
            case evidenceTokens = "evidence_tokens", freeRaceBudgetS = "free_race_budget_s", fetchDeadlineS = "fetch_deadline_s"
        }
    }
    public struct Tools: Sendable, Decodable, Equatable {
        public var source: String
        public var maxPerStep: [String: Int], schemaTokenCap: [String: Int], resultCap: [String: Int], maxSteps: [String: Int]
        enum CodingKeys: String, CodingKey {
            case source
            case maxPerStep = "max_per_step", schemaTokenCap = "schema_token_cap", resultCap = "result_cap", maxSteps = "max_steps"
        }
    }
    public struct Skills: Sendable, Decodable, Equatable {
        public var source: String
        public var candidatesM: [String: Int], maxActive: [String: Int], bodyTokens: [String: Int], theta: [String: Double]
        /// M7.T13 step 3 (K-NEW-SKILL-1): tiers whose selector pre-loads the top skill's body when its similarity is ≥ θ
        /// (absent = T0 only, the PRD default).
        public var preload: [String: Bool]?
        enum CodingKeys: String, CodingKey {
            case source, theta, preload
            case candidatesM = "candidates_m", maxActive = "max_active", bodyTokens = "body_tokens"
        }
    }
    public struct Connections: Sendable, Decodable, Equatable {
        public var source: String
        public var maxLocalServers: [String: Int], idleShutdownMin: [String: Int]
        enum CodingKeys: String, CodingKey {
            case source
            case maxLocalServers = "max_local_servers", idleShutdownMin = "idle_shutdown_min"
        }
    }

    public var version: Int
    public var files: Files
    public var search: Search?
    public var tools: Tools?
    public var skills: Skills?
    public var connections: Connections?

    public init(version: Int, files: Files, search: Search? = nil, tools: Tools? = nil, skills: Skills? = nil,
                connections: Connections? = nil) {
        self.version = version; self.files = files; self.search = search; self.tools = tools; self.skills = skills
        self.connections = connections
    }

    /// M7.T01: a tier row value, falling back to T1's (an unknown tier never crashes).
    public static func cell<V>(_ row: [String: V]?, _ tier: String) -> V? { row?[tier] ?? row?["T1"] }

    public static let tiers = ["T0", "T1", "T2", "T3", "T4"]

    /// The bundled file (tests read it raw to check the decoded rows, M7.T14).
    public static var resourceURL: URL? { Bundle.module.url(forResource: "tier-budgets", withExtension: "json") }

    public static let shared: TierBudgets = {
        guard let url = resourceURL,
              let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(TierBudgets.self, from: data) else {
            // A missing/broken resource: empty rows, so every reader takes its own documented fallback (M7.T14: the
            // numbers are never retyped here, `no-retyped-budgets.py`).
            return TierBudgets(version: 0, files: Files(retrievalTopK: [:], prefillTPS: [:], prefillTPSTierDefault: [:]))
        }
        return b
    }()

    /// M6.T07: DuckDB memory cap per tier (T0 256 MB … T3+ 2 GB); unknown tier → T1's.
    public func duckDBMemoryMB(tier: String) -> Int { files.duckDBMemoryMB[tier] ?? files.duckDBMemoryMB["T1"] ?? 512 }
    /// M6.T07: sheet profile block cap per tier (T0 1.5K, T1+ 3K tokens).
    public func sheetProfileTokens(tier: String) -> Int { files.sheetProfileTokens[tier] ?? files.sheetProfileTokens["T1"] ?? 3000 }

    public func topK(tier: String) -> Int { files.retrievalTopK[tier] ?? files.retrievalTopK["T1"] ?? 6 }

    /// The floor when even the tier has no default (never crash, never divide by zero).
    public static let floorPrefillTPS: Double = 300

    /// The model's prefill rate (R-270 AC1). A key missing from `prefill_tps` (a catalog model update renamed or added
    /// a model) or a non-positive / non-finite value falls back to the tier's conservative default (A-M6-T02a), then
    /// to `floorPrefillTPS`: the rule then picks excerpts sooner rather than a slow inline prefill.
    public func prefillTPS(modelKey: String, tier: String) -> Double {
        if let v = files.prefillTPS[modelKey], v.isFinite, v > 0 { return v }
        if let v = files.prefillTPSTierDefault[tier], v.isFinite, v > 0 { return v }
        return Self.floorPrefillTPS
    }
}
