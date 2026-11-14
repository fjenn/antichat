// AT-235 part 1 (R-235 AC1) — M2.T22: with a tool chip present, a model that would answer in text calls the chip's tool
// on 50/50 turns (ScriptedEngine honours a forced `tool_choice` like the engines' constrained decoding), the first
// request carries `tool_choice` = that function (OpenAI JSON `{"type":"function",…}`; llama-server gets `required`
// over that tool, LlamaToolChoiceTests), later steps go back to `auto`, and a chip forces even a conversational turn.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ChipForcesToolTests {
    static let textOnly = #"{"t":"textDelta","v":"Sure, here is a description instead.","delayMs":0}"#

    @Test(arguments: [("image", "create_image"), ("video", "create_video"), ("web", "web_search"), ("file", "create_file"),
                      ("tool:memory_write", "memory_write")])
    func chipForcesToolEveryTurn(chip: String, tool: String) async throws {
        let router = try await RouterStubs.router()
        var forced = 0
        for i in 0..<50 {
            let h = try ToolLoopHarness(script: Self.textOnly, tier: .t1, tools: RouterStubs.all, selection: .standard, router: router)
            await h.controller.setChips([chip])
            let (_, a) = await h.send(i % 5 == 0 ? "thanks!" : "something nice for my mum, turn \(i)")
            _ = try await h.log.waitFinished(a)
            let reqs = await h.controller.requests
            #expect(reqs[0].toolChoice == .function(tool))
            #expect(reqs[0].tools.contains { $0.name == tool })
            let json = try JSONSerialization.data(withJSONObject: ["tool_choice": try #require(reqs[0].toolChoice).openAIValue])
            #expect(String(decoding: json, as: UTF8.self).contains(#""name":"\#(tool)""#))
            if reqs.count > 1 { #expect(reqs[1].toolChoice == .auto || reqs[1].toolChoice == ToolChoice.none) }
            if h.registry.invocations(of: tool) == 1 { forced += 1 }
        }
        #expect(forced == 50)
    }

    @Test func noChipNoForce() async throws {
        let h = try ToolLoopHarness(script: Self.textOnly, tier: .t1, tools: RouterStubs.all, selection: .standard,
                                    router: try await RouterStubs.router())
        let (_, a) = await h.send("tell me a joke about penguins")
        _ = try await h.log.waitFinished(a)
        #expect(await h.controller.requests[0].toolChoice == .auto)
        #expect(RouterStubs.names.allSatisfy { h.registry.invocations(of: $0) == 0 })
    }

    @Test func chipToolMapping() {
        #expect(ChipOverride.toolName(forChip: "image") == "create_image")
        #expect(ChipOverride.toolName(forChip: "tool:echo") == "echo")
        #expect(ChipOverride.toolName(forChip: "files") == nil)
        let offered = [ToolSchema(name: "web_search", description: "", parametersJSON: "{}")]
        #expect(ChipOverride.forcedTool(chips: ["image", "web"], offered: offered) == "web_search")  // image not offered
    }
}
