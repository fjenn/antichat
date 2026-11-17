// M7.T14 step 2–3 (R-266 AC1/AC2, R-268 AC3; blueprint B §B4.2 step 2): which of the turn's eligible tools the model
// sees on a step ("Load tools when needed"). Eligible = registered, available, switched on for this chat, not Blocked,
// and online-possible (OnlineToolGate) — decided before this runs. Then, in priority order:
//   1. the forced set: the chip tools (the forced chip tool first) and an active skill's `allowed-tools`;
//   2. the pre-router's intent tools (M2.T22 routes whose margin over chat reached `low`, best first);
//   3. similarity top-k over the rest (ToolIndex: BM25 + embedding, RRF; only tools that pass its relevance gate);
//   4. the always-on minimal set (`get_time`) when a slot is left;
//   5. `find_tools` (FindToolsTool) whenever some eligible tool was left out, so the model can still reach it.
// k = the tier's `tools.max_per_step` minus the forced set minus `find_tools`, read from tier-budgets.json (never
// retyped, A-M7-04). R-235 AC2 holds T0–T2 to four (ToolPruner.limit); since A-M7-T14a (a) (lead decision
// 2026-11-10) the budget file says the same (T0 3 · T1 4 · T2 4), and `cap` keeps the min as a guard against a file
// edit that would exceed R-235. SchemaCompactor then enforces `tools.schema_token_cap`.
// When every eligible tool fits both caps, all are offered (nothing to select; no `find_tools`).
// "Always offer all enabled tools" (`ToolAccess.all`) skips selection: every eligible tool, forced first, bounded by
// the schema token cap only (the mode warns on T0–T2, R-268 AC3).
// The result's order is not the prompt's: the composer renders tools in canonical name order (R-269), so the same set
// always yields the same tool block and cached prefix.
import AntiChatEngineProtocol
import Foundation

public enum ToolSelector {
    /// The tier's tool budget (tier-budgets.json `tools`, A-M7-04).
    public struct Budget: Sendable, Hashable {
        public var maxPerStep: Int
        public var schemaTokenCap: Int
        public init(maxPerStep: Int, schemaTokenCap: Int) {
            self.maxPerStep = maxPerStep
            self.schemaTokenCap = schemaTokenCap
        }

        public static func forTier(_ tier: DeviceTier, budgets: TierBudgets = .shared) -> Budget {
            let t = tier.rawValue
            return Budget(maxPerStep: TierBudgets.cell(budgets.tools?.maxPerStep, t) ?? ToolPruner.limit,
                          schemaTokenCap: TierBudgets.cell(budgets.tools?.schemaTokenCap, t) ?? 1200)
        }
    }

    /// The embed-cosine floor of the similarity leg (ToolIndex relevance gate). Swept on tool-select-200 with
    /// Qwen3-Embedding-0.6B (`antichat-bench tool-select --sweep`; 0.52–0.56 is the plateau at T0 and T2,
    /// build/at/AT-266/). A tuning value, not a tier budget.
    public static let minEmbedCosine: Float = 0.54

    /// A route with several tools (`file_output`: one per file type) lists them most general first; the similarity
    /// leg knows which of them the message is about, so within that family the best hit goes first (the rest keep
    /// their order). Without this a small tier's slots would hold the document and spreadsheet tools for "make a deck".
    static func rankFamily(_ routed: [String], hits: [ToolIndex.Hit]) -> [String] {
        let family = Set(Route.fileTools)
        let members = routed.filter(family.contains)
        guard members.count > 1 else { return routed }
        var rank: [String: Int] = [:]
        for (i, h) in hits.enumerated() where rank[h.name] == nil { rank[h.name] = i }
        let sorted = members.enumerated().sorted {
            let a = rank[$0.element] ?? .max, b = rank[$1.element] ?? .max
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        var next = sorted.makeIterator()
        return routed.map { family.contains($0) ? next.next() ?? $0 : $0 }
    }

    public enum Reason: String, Sendable, Hashable { case forced, routed, similar, alwaysOn, all, discovery }

    public struct Selection: Sendable, Hashable {
        /// What the model sees this step (find_tools included when offered); selection order.
        public var tools: [ToolSchema]
        /// Why each tool is in the set.
        public var reasons: [String: Reason]
        /// The selector's own pick: the first forced / routed / relevant similar tool (nil = no tool needed).
        public var top: String?
        /// Eligible tools left out (find_tools can bring them in).
        public var leftOut: [String]
        public var offersFindTools: Bool { reasons[FindToolsTool.name] != nil }
    }

    /// The per-step count cap: `max_per_step` (= R-235 AC2's four on T0–T2 since A-M7-T14a (a); the min is a guard).
    public static func cap(_ tier: DeviceTier, budget: Budget) -> Int {
        ToolPruner.prunes(tier) ? min(budget.maxPerStep, ToolPruner.limit) : budget.maxPerStep
    }

    /// The slots for tools other than `find_tools`. A pinned tool (`memory` while memory is On) rides on top of the
    /// tier's count where R-235 AC2's four allows it (T0: 3 → 4) and on T3+; on T1/T2 (already four) it takes one of
    /// the slots. A forced pick is never cut; a pinned one is, when the forced set alone fills the step.
    static func slots(cap: Int, tier: DeviceTier, forced: Int, pinned: Int) -> Int {
        let extra = ToolPruner.prunes(tier) ? min(pinned, max(0, ToolPruner.limit - cap)) : pinned
        return max(cap - 1 + extra, forced)
    }

    /// `pinned`: offered on every step whatever the message is about (after the forced set, before the routed tools),
    /// never the selector's `top`, and outside the schema token cap (its cost is added, not taken from the others).
    public static func select(eligible: [ToolSchema], forced: [String] = [], pinned: [String] = [], routed: [String] = [],
                              hits: [ToolIndex.Hit] = [], access: ToolAccess = .whenNeeded, tier: DeviceTier,
                              budget: Budget, capOverride: Int? = nil) -> Selection {
        let byName = Dictionary(eligible.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let forcedIn = unique(forced).filter { byName[$0] != nil }
        let pinnedIn = unique(pinned).filter { byName[$0] != nil && !forcedIn.contains($0) }
        let pinnedTokens = SchemaCompactor.tokens(pinnedIn.compactMap { byName[$0] })
        let routed = rankFamily(unique(routed), hits: hits)
        let relevant = hits.filter(\.relevant).map(\.name)
        let top = (forcedIn + routed + relevant).first { byName[$0] != nil }
        var reasons: [String: Reason] = [:]
        func pick(_ names: [String]) -> [ToolSchema] { names.compactMap { byName[$0] } }

        if access == .all {
            let first = forcedIn + pinnedIn
            let order = first + eligible.map(\.name).filter { !first.contains($0) }
            var out = SchemaCompactor.fit(pick(order), cap: budget.schemaTokenCap + pinnedTokens, pinned: Set(first))
            for t in out { reasons[t.name] = forcedIn.contains(t.name) ? .forced : .all }
            let left = eligible.map(\.name).filter { reasons[$0] == nil }
            if !left.isEmpty { out.append(FindToolsTool.schema); reasons[FindToolsTool.name] = .discovery }
            return Selection(tools: out, reasons: reasons, top: top, leftOut: left)
        }

        let cap = capOverride ?? cap(tier, budget: budget)  // capOverride: the bench's diagnostic only
        if eligible.count <= cap, SchemaCompactor.tokens(eligible) <= budget.schemaTokenCap {
            for t in eligible { reasons[t.name] = forcedIn.contains(t.name) ? .forced : .all }
            return Selection(tools: eligible, reasons: reasons, top: top, leftOut: [])
        }
        // One slot is find_tools; a forced pick is never cut.
        let slots = slots(cap: cap, tier: tier, forced: forcedIn.count, pinned: pinnedIn.count)
        var order: [(String, Reason)] = forcedIn.map { ($0, .forced) }
        for n in pinnedIn { order.append((n, .alwaysOn)) }
        for n in routed { order.append((n, .routed)) }
        for n in relevant { order.append((n, .similar)) }
        for n in ToolPruner.alwaysOn { order.append((n, .alwaysOn)) }
        var chosen: [String] = []
        for (n, r) in order where byName[n] != nil && reasons[n] == nil && chosen.count < slots {
            chosen.append(n)
            reasons[n] = r
        }
        var out = SchemaCompactor.fit(pick(chosen),
                                      cap: max(0, budget.schemaTokenCap - SchemaCompactor.tokens(FindToolsTool.schema)) + pinnedTokens,
                                      pinned: Set(forcedIn + pinnedIn))
        reasons = reasons.filter { k, _ in out.contains { $0.name == k } }
        out.append(FindToolsTool.schema)
        reasons[FindToolsTool.name] = .discovery
        return Selection(tools: out, reasons: reasons, top: top, leftOut: eligible.map(\.name).filter { reasons[$0] == nil })
    }

    /// The tools `find_tools` brings in for the next step: the forced set kept, then the found tools, then what was
    /// offered before, up to the same cap (find_tools stays offered).
    public static func afterDiscovery(found: [String], previous: [ToolSchema], eligible: [ToolSchema], forced: [String],
                                      pinned: [String] = [], tier: DeviceTier, budget: Budget, access: ToolAccess) -> [ToolSchema] {
        let byName = Dictionary(eligible.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let forcedIn = unique(forced).filter { byName[$0] != nil }
        let pinnedIn = unique(pinned).filter { byName[$0] != nil && !forcedIn.contains($0) }
        let prev = previous.map(\.name).filter { $0 != FindToolsTool.name }
        let order = unique(forcedIn + pinnedIn + found + prev).filter { byName[$0] != nil }
        let slots = access == .all ? order.count
            : slots(cap: cap(tier, budget: budget), tier: tier, forced: forcedIn.count, pinned: pinnedIn.count)
        let chosen = Array(order.prefix(slots)).compactMap { byName[$0] }
        let cap = max(0, budget.schemaTokenCap - SchemaCompactor.tokens(FindToolsTool.schema))
            + SchemaCompactor.tokens(pinnedIn.compactMap { byName[$0] })
        return SchemaCompactor.fit(chosen, cap: cap, pinned: Set(forcedIn + pinnedIn)) + [FindToolsTool.schema]
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
