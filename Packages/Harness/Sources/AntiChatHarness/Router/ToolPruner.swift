// M2.T22 step 5 (R-235 AC2): on T0–T2 the model sees at most four tools per turn — a forced chip tool first, then the
// tools of the routes whose margin over chat reached their `low` threshold (best first), then the always-on minimal set, then the
// remaining tools by their best route score and name — so small models are not handed every schema. T3+ unchanged.
// The tools left out are not lost: a chip forces any of them, and the discover/load meta-tool (R-266) reaches the
// rest once it exists (M7).
import AntiChatEngineProtocol
import Foundation

public enum ToolPruner {
    public static let limit = 4
    /// Cheap, general tools kept when there is room (M1's always-on `get_time`).
    public static let alwaysOn: [String] = ["get_time"]
    static let editTool = "edit_image"

    public static func prunes(_ tier: DeviceTier) -> Bool { tier == .t0 || tier == .t1 || tier == .t2 }

    /// The routes' tools in route order (M7.T14 ToolSelector's intent leg): the decided route's tools first (its
    /// medium may come from MediumCue rather than the raw scores), then every route whose margin over chat reached
    /// its `low` threshold, best first. Deduplicated.
    public static func routedTools(scores: [Route: Float], thresholds: [Route: RouteThreshold], top: Route?) -> [String] {
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        // M4.T13: a picture route also brings `edit_image` (present only when Photo is installed; callers keep only
        // eligible tools), right after the route's own tools, so "make the cake pink" can edit the picture in focus.
        top?.tools.forEach(add)
        if top?.isImage == true { add(editTool) }
        let chat = scores[.chat] ?? 0
        let ranked = Route.intents.filter { r in (scores[r] ?? -1) - chat >= (thresholds[r]?.low ?? .infinity) }
            .sorted { (scores[$0] ?? 0) > (scores[$1] ?? 0) }
        for r in ranked {
            r.tools.forEach(add)
            if r.isImage { add(editTool) }
        }
        return out
    }

    public static func prune(_ tools: [ToolSchema], scores: [Route: Float], thresholds: [Route: RouteThreshold],
                             forced: String?, top: Route? = nil, tier: DeviceTier) -> [ToolSchema] {
        guard prunes(tier), tools.count > limit else { return tools }
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        func add(_ n: String) { if byName[n] != nil, !order.contains(n) { order.append(n) } }
        if let forced { add(forced) }
        routedTools(scores: scores, thresholds: thresholds, top: top).forEach(add)
        alwaysOn.forEach(add)
        // Best route score per tool (tools no route maps to: none), then by name.
        func best(_ n: String) -> Float { Route.intents.filter { $0.tools.contains(n) }.compactMap { scores[$0] }.max() ?? -2 }
        for n in byName.keys.sorted(by: { (best($0), $1) > (best($1), $0) }) { add(n) }
        return order.prefix(limit).compactMap { byName[$0] }
    }
}
