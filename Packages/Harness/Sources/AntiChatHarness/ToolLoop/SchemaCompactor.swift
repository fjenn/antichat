// M7.T14 step 2 (R-266; blueprint B §B4.2 step 2.5): the tier's tool-schema token cap (`tools.schema_token_cap`,
// tier-budgets.json). The schemas are measured as the prompt carries them — ToolBlockRenderer's compact form (one-line
// description, no nested `description` annotations, sorted keys; the Osaurus compaction ported in M1.T14) — with the
// vendored TokenEstimator. Tools are kept in priority order while the total fits; pinned tools (forced chips,
// `find_tools`) are always kept, so the user's explicit pick is never dropped for its size.
import AntiChatEngineProtocol
import Foundation
import OsaurusVendored

public enum SchemaCompactor {
    /// The estimated tokens one tool costs in the tool block (its compact rendered line).
    public static func tokens(_ tool: ToolSchema) -> Int {
        let r = ToolBlockRenderer()
        return TokenEstimator.estimate(r.render(r.canonical([tool])))
    }

    public static func tokens(_ tools: [ToolSchema]) -> Int { tools.reduce(0) { $0 + tokens($1) } }

    /// `ordered` (best first) cut to `cap` tokens; `pinned` names stay whatever their size. Order is kept.
    public static func fit(_ ordered: [ToolSchema], cap: Int, pinned: Set<String> = []) -> [ToolSchema] {
        var used = ordered.filter { pinned.contains($0.name) }.reduce(0) { $0 + tokens($1) }
        var out: [ToolSchema] = []
        for t in ordered {
            if pinned.contains(t.name) { out.append(t); continue }
            let c = tokens(t)
            if used + c <= cap { out.append(t); used += c }
        }
        return out
    }
}
