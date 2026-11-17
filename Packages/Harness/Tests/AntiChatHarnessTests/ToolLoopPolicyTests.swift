// M1.T16 AT-232 (1) + (4, harness half): a script that always calls a tool (tool-loop-runaway) stops after exactly
// 3/6/6/6/8 steps for T0/T1/T2/T3/T4; every call and result is a `message_part` row (`tool_result` untrusted) with
// an activity line; the limit ends the reply with `tool.loopLimit`, and [Continue] (`.continueTools`) resumes the
// same reply with a fresh budget.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ToolLoopPolicyTests") struct ToolLoopPolicyTests {
    @Test func stepTableByTier() {
        #expect(DeviceTier.allCases.map(ToolLoopPolicy.steps(for:)) == [3, 6, 6, 6, 8])
        #expect(ToolLoopPolicy(maxSteps: 0).maxSteps == 1)
        #expect(DeviceTier(.T4) == .t4)
    }

    @Test(arguments: DeviceTier.allCases)
    func runawayStopsAtTheTierLimit(_ tier: DeviceTier) async throws {
        let h = try ToolLoopHarness(script: runawayScript, tier: tier)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a, timeout: .seconds(20))
        let n = ToolLoopPolicy.steps(for: tier)
        #expect(r.status == .done)
        // n tool steps, then the one text-only step that reports on the spent budget.
        #expect(await h.controller.requests.count == n + 1, "\(tier): model steps")
        #expect(await h.controller.requests.last?.toolChoice == ToolChoice.none)
        #expect(h.registry.invocations(of: "echo") == n, "\(tier): echo ran once per step")
        // Every call and result is persisted; results are untrusted; one activity line per call + the limit notice.
        #expect(try h.parts(a, .toolCall).count == n)
        let results = try h.parts(a, .toolResult)
        #expect(results.count == n)
        #expect(results.allSatisfy { $0.untrusted })
        let acts = try h.activities(a)
        #expect(acts.filter { $0.kind == .tool }.count == n)
        #expect(acts.filter { $0.kind == .tool }.allSatisfy { $0.state == .done })
        #expect(acts.last?.isLoopLimit == true)
        #expect(acts.last?.steps == n)
        // Each step sees the previous steps' calls and results (step k: k-1 assistant steps + k-1 results).
        let last = await h.controller.requests[n - 1]
        let history = last.flattenedMessages
        #expect(history.filter { $0.role == .assistant && !$0.toolCalls.isEmpty }.count == n - 1)
        #expect(history.filter { $0.role == .tool }.count == n - 1)
    }

    @Test func continueResumesWithAFreshBudget() async throws {
        let h = try ToolLoopHarness(script: runawayScript, tier: .t0)
        let (_, a) = await h.send()
        _ = try await h.log.waitFinished(a, timeout: .seconds(20))
        #expect(h.registry.invocations(of: "echo") == 3)
        await h.controller.start(.continueTools(assistantID: a), assistantID: a)
        try await h.log.wait(.seconds(20)) { log in
            log.all.filter { if case .finished = $0.kind { $0.assistantID == a } else { false } }.count == 2
        }
        #expect(h.registry.invocations(of: "echo") == 6)
        #expect(await h.controller.requests.count == 4)
        // The resumed steps see the earlier calls (history rebuilt from the parts) and run new ones.
        let first = await h.controller.requests.first!
        #expect(first.flattenedMessages.filter { $0.role == .tool }.count == 3)
        #expect(try h.parts(a, .toolResult).count == 6)
        #expect(try MessageRepository(h.database).message(a)?.status == .done)
        #expect(try h.activities(a).last?.isLoopLimit == true)
    }

    @Test func historyRebuildFromParts() {
        let parts = [
            PartContent(kind: .text, body: "Let me check."),
            PartContent(kind: .toolCall, body: #"{"arguments":"{\"text\":\"a\"}","id":"c1","name":"echo"}"#),
            PartContent(kind: .activity, body: "{}"),
            PartContent(kind: .toolResult, body: #"{"id":"c1","name":"echo","result":"a"}"#, untrusted: true),
            PartContent(kind: .toolCall, body: #"{"arguments":"{}","id":"c2","name":"get_time"}"#),
        ]
        let h = ToolLoopHistory.messages(from: parts)
        #expect(h.count == 2)
        #expect(h[0].role == .assistant && h[0].toolCalls == [ToolCallRef(id: "c1", name: "echo", argumentsJSON: #"{"text":"a"}"#)])
        #expect(h[1].role == .tool && h[1].toolCallID == "c1" && h[1].content == "a" && h[1].toolName == "echo")
    }

    @Test func noToolsNoLoop() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"Hi.","delayMs":1}"#)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done && r.text == "Hi.")
        #expect(await h.controller.requests.count == 1)
        #expect(await h.controller.requests[0].tools.map(\.name).sorted() == ["echo", "get_time", "write_note"])
    }
}
