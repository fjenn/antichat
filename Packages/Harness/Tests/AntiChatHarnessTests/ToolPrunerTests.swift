// AT-235 part 1 (R-235 AC2) — M2.T22: on T0/T1/T2 the request exposes ≤ 4 tools (forced chip tool first, then the
// best-scoring routes' tools, then get_time); T3/T4 unchanged (all eight fit the tier's cap). M7.T14: the set comes
// from ToolSelector (ToolPruner.routedTools is its intent leg).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ToolPrunerTests {
    @Test(arguments: [DeviceTier.t0, .t1, .t2, .t3, .t4])
    func requestToolCountPerTier(tier: DeviceTier) async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"ok","delayMs":0}"#, tier: tier, tools: RouterStubs.all,
                                    selection: .standard, router: try await RouterStubs.router())
        let (_, a) = await h.send("search the web for today's football results")
        _ = try await h.log.waitFinished(a)
        let tools = await h.controller.requests[0].tools
        // M7.T14 (A-M7-T14a): ToolSelector exposes the step's set — ≤ 4 on T0–T2 (R-235 AC2) and ≤ the tier's
        // `tools.max_per_step`: the routed tool first, `get_time` while a slot is left, `find_tools` for the rest.
        let cap = ToolSelector.cap(tier, budget: .forTier(tier))
        if ToolPruner.prunes(tier) {
            #expect(tools.count <= 4 && tools.count <= cap)
            #expect(tools.contains { $0.name == "web_search" } && tools.contains { $0.name == FindToolsTool.name })
        } else {
            #expect(tools.count == 8)
        }
    }

    @Test func orderForcedThenRoutesThenAlwaysOn() {
        let tools = RouterStubs.all.map(\.schema)
        let th = Dictionary(uniqueKeysWithValues: Route.intents.map { ($0, RouteThreshold(low: 0.5, high: 0.7)) })
        let scores: [Route: Float] = [.webNeeded: 0.8, .fileOutput: 0.6, .imageCreate: 0.3, .chat: 0.2]
        let p = ToolPruner.prune(tools, scores: scores, thresholds: th, forced: "create_video", tier: .t1)
        #expect(p.map(\.name) == ["create_video", "web_search", "get_time", "create_document"])  // file's margin 0.4 < 0.5
        let noScores = ToolPruner.prune(tools, scores: [:], thresholds: th, forced: nil, tier: .t0)
        #expect(noScores.count == 4 && noScores.first?.name == "get_time")
        #expect(ToolPruner.prune(tools, scores: scores, thresholds: th, forced: nil, tier: .t3).count == 8)
        let few = Array(tools.prefix(3))
        #expect(ToolPruner.prune(few, scores: scores, thresholds: th, forced: nil, tier: .t0).count == 3)
    }
}
