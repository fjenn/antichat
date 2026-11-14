// M1.T16 / D-023: ToolSelection — no tools for a chat-only model (the starter) or a purely conversational turn
// (vendored CapabilityQueryIntent), otherwise every tool with `tool_choice: auto` and the selection clause in the
// tool layer (stable prefix, after the tool block). The clause carries no content rule (R-241 rule 3 patterns).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ToolSelectionTests") struct ToolSelectionTests {
    static let tools = [ScriptedTools.getTime().schema, ScriptedTools.echo().schema]

    @Test func chatOnlyModelGetsNoTools() {
        let p = ToolSelection.plan(tools: Self.tools, userText: "What time is it in Tokyo?", modelKey: "chat-0.8b")
        #expect(p.tools.isEmpty && p.toolChoice == nil && p.clause == nil && p.withheld == .chatOnlyModel)
    }

    @Test(arguments: ["Hi there", "thanks, that's perfect!", "ok", "Good morning", "bye"])
    func conversationalTurnGetsNoTools(_ text: String) {
        let p = ToolSelection.plan(tools: Self.tools, userText: text, modelKey: "chat-9b-q4")
        #expect(p.tools.isEmpty && p.withheld == .conversational, "\(text)")
    }

    @Test(arguments: ["What time is it in Tokyo?", "thanks, now check the weather", "say hello world with python", "do it"])
    func requestsGetToolsAndTheClause(_ text: String) {
        let p = ToolSelection.plan(tools: Self.tools, userText: text, modelKey: "chat-9b-q4")
        #expect(p.tools.count == 2 && p.toolChoice == .auto && p.clause == ToolSelection.clause, "\(text)")
    }

    @Test func offVariantIsTheRawRequest() {
        let p = ToolSelection.plan(tools: Self.tools, userText: "Hi there", variant: .off)
        #expect(p.tools.count == 2 && p.clause == nil)
    }

    @Test func clauseIsAStableLayerAfterTheToolBlock() {
        let composed = PromptComposer().compose(PromptInputs(tools: Self.tools, toolClause: ToolSelection.clause))
        let ids = composed.layers.map(\.id)
        #expect(ids.contains(PromptLayerID.toolUse))
        #expect(ids.firstIndex(of: PromptLayerID.toolUse)! < ids.firstIndex(of: PromptLayerID.date)!)
        #expect(composed.stablePrefix.contains(ToolSelection.clause))
        // Same inputs → same bytes (R-269); no tools → no clause.
        #expect(PromptComposer().compose(PromptInputs(tools: Self.tools, toolClause: ToolSelection.clause)).stableSHA256
            == composed.stableSHA256)
        #expect(!PromptComposer().compose(PromptInputs(toolClause: ToolSelection.clause)).stablePrefix.contains("Call a tool"))
    }

    @Test func evalItemsPutTheClauseAfterTheSystemMessage() {
        let items = ToolSelection.items(
            [ChatMessage(role: .system, content: "You are a coding assistant."), ChatMessage(role: .user, content: "hi")],
            clause: ToolSelection.clause)
        let req = ChatRequest(modelSlot: .scripted("x"), messages: items)
        let flat = req.flattenedMessages
        #expect(flat.count == 2)
        #expect(flat[0].content == "You are a coding assistant.\n\n" + ToolSelection.clause)
        #expect(ToolSelection.items([ChatMessage(role: .user, content: "hi")], clause: nil).count == 1)
    }

    @Test func turnWithToolsCarriesTheClauseAndConversationalTurnDoesNot() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"Hello!","delayMs":1}"#, selection: .standard)
        let (_, a) = await h.send("What time is it?")
        _ = try await h.log.waitFinished(a)
        let first = await h.controller.requests[0]
        #expect(first.toolChoice == .auto && !first.tools.isEmpty)
        #expect(first.flattenedMessages.first?.content.contains(ToolSelection.clause) == true)
        let (_, a2) = await h.send("thanks!", parent: a)
        _ = try await h.log.waitFinished(a2)
        let second = await h.controller.requests[0]
        #expect(second.tools.isEmpty && second.toolChoice == nil)
    }
}
