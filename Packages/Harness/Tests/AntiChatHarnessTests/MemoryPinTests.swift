// Memory saves lasting facts on its own, so the `memory` tool is offered on every step of a chat that may write memory,
// on every tier. Before, per-message selection gave a small tier two or three slots that `memory` only got when the
// message looked like a memory request, and the prompt's one-line description did not say to save unasked.
import AntiChatEngineProtocol
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct MemoryPinTests {
    static func eligible() throws -> [ToolSchema] {
        let memory = MemoryRuntime(database: try AppDatabase.inMemory(), policy: { MemoryPolicy() }).tool().schema
        return RouterStubs.all.map(\.schema) + [memory] + (1...6).map {
            ToolSchema(name: "extra_\($0)", description: "Extra tool \($0).", parametersJSON: #"{"type":"object","properties":{}}"#)
        }
    }

    @Test(arguments: [DeviceTier.t0, .t1, .t2, .t3, .t4])
    func pinnedMemoryIsOfferedForAnUnrelatedMessage(tier: DeviceTier) throws {
        let all = try Self.eligible()
        let budget = ToolSelector.Budget.forTier(tier)
        let hits = [ToolIndex.Hit(name: "web_search", fusedScore: 0.9, relevant: true),
                    ToolIndex.Hit(name: "create_image", fusedScore: 0.8, relevant: true),
                    ToolIndex.Hit(name: "echo", fusedScore: 0.7, relevant: true)]
        let without = ToolSelector.select(eligible: all, routed: ["web_search"], hits: hits, tier: tier, budget: budget)
        let with = ToolSelector.select(eligible: all, pinned: [MemoryTool.name], routed: ["web_search"], hits: hits, tier: tier,
                                       budget: budget)
        if ToolPruner.prunes(tier) {
            #expect(!without.tools.contains { $0.name == MemoryTool.name }, "the gap: memory lost the slots on \(tier)")
            #expect(with.tools.count <= ToolPruner.limit, "R-235 AC2 holds with the pin")
        }
        #expect(with.tools.contains { $0.name == MemoryTool.name })
        #expect(with.tools.contains { $0.name == "web_search" } && with.top == "web_search", "the pin is never the pick")
        // T0 keeps both of its message-picked slots; the pin rides on top (3 → 4).
        if tier == .t0 { #expect(with.tools.map(\.name).filter { $0 != MemoryTool.name } == without.tools.map(\.name)) }
        // find_tools keeps it on the next step.
        let next = ToolSelector.afterDiscovery(found: ["extra_1", "extra_2", "extra_3"], previous: with.tools, eligible: all, forced: [],
                                               pinned: [MemoryTool.name], tier: tier, budget: budget, access: .whenNeeded)
        #expect(next.contains { $0.name == MemoryTool.name } && next.contains { $0.name == "extra_1" })
        if ToolPruner.prunes(tier) { #expect(next.count <= ToolPruner.limit) }
    }

    /// The cost of the pin: the tool's compact line in the tool block, once per request (part of the cached prefix).
    @Test func thePinCostsUnderAHundredAndSeventyFiveTokens() throws {
        let memory = try #require(try Self.eligible().first { $0.name == MemoryTool.name })
        let cost = SchemaCompactor.tokens(memory)
        print("memory tool schema tokens: \(cost)")
        #expect(cost <= 175)
        // The schema cap of the other tools is not reduced by it (T0's 600 would otherwise lose a file tool).
        let big = ToolSchema(name: "big", description: String(repeating: "word ", count: 30) + ".",
                             parametersJSON: #"{"type":"object","properties":{"a":{"type":"string"}}}"#)
        let cap = SchemaCompactor.tokens(big) + SchemaCompactor.tokens(FindToolsTool.schema)
        let s = ToolSelector.select(eligible: try Self.eligible() + [big], pinned: [MemoryTool.name], routed: ["big"], tier: .t0,
                                    budget: .init(maxPerStep: 3, schemaTokenCap: cap))
        #expect(s.tools.contains { $0.name == "big" } && s.tools.contains { $0.name == MemoryTool.name })
    }

    /// What the model actually reads (the block keeps one sentence of a description) tells it to save unasked.
    @Test func theOneLineDescriptionSaysToSaveUnasked() throws {
        let line = try #require(ToolBlockRenderer.oneLineToolDescription(MemoryTool.description))
        #expect(line.count <= 180 && !line.hasSuffix("..."))
        #expect(line.contains("on your own") && line.contains("without asking"))
        // … and not to claim a save it did not make (it said "I have noted your preference" without a call).
        #expect(line.contains("never say you saved or noted one unless you called this tool"))
    }

    @Test(arguments: [(MemoryPolicy.Mode.on, true), (.paused, false), (.off, false)])
    func aTurnOnTheSmallestTierOffersMemoryOnlyWhileItMayWrite(mode: MemoryPolicy.Mode, offered: Bool) async throws {
        let db = try AppDatabase.inMemory()
        let memory = MemoryRuntime(database: db, policy: { MemoryPolicy(mode: mode) })
        let registry = ToolRegistry(RouterStubs.all + [memory.tool()])
        let runtime = ToolLoopHarness.runtime(registry: registry, database: db, tier: .t0, selection: .standard)
        let chatID = StorageID.make()
        let c = TurnController(chatID: chatID, database: db,
                               engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"Paris.","delayMs":0}"#)),
                               tools: runtime, memory: memory) { .scripted("inline") }
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "By the way I am a nurse. What is the capital of France?", parentID: nil),
                      assistantID: a)
        _ = try await log.waitFinished(a)
        let tools = await c.requests[0].tools.map(\.name)
        #expect(tools.contains(MemoryTool.name) == offered, "\(tools)")
        #expect(tools.count <= ToolPruner.limit)
    }
}
