// M1.T16 AT-232 (3): a malformed call gets exactly one repair attempt (its validation error as the call's result),
// then a text-only answer (`toolChoice = none` in the last request).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("RepairRetryTests") struct RepairRetryTests {
    static let echo = ScriptedTools.echo().schema

    @Test func validation() {
        #expect(RepairRetry.problem(name: "echo", argumentsJSON: #"{"text":"hi"}"#, tools: [Self.echo]) == nil)
        #expect(RepairRetry.problem(name: "echo", argumentsJSON: "{bad", tools: [Self.echo])?.contains("not a JSON object") == true)
        #expect(RepairRetry.problem(name: "echo", argumentsJSON: #"{"text":5}"#, tools: [Self.echo])?.contains("schema") == true)
        #expect(RepairRetry.problem(name: "echo", argumentsJSON: "{}", tools: [Self.echo])?.contains("required") == true)
        #expect(RepairRetry.problem(name: "nope", argumentsJSON: "{}", tools: [Self.echo])?.contains("no tool named") == true)
    }

    @Test func oneRepairThenFinalAnswer() {
        var r = RepairRetry()
        guard case .repair(let prompt) = r.onMalformed(name: "echo", problem: "bad") else { Issue.record("no repair"); return }
        #expect(prompt.contains("bad"))
        #expect(r.onMalformed(name: "echo", problem: "bad again") == .finalAnswer)
        #expect(r.repairsUsed == 1)
    }

    @Test func malformedTwiceEndsTextOnly() async throws {
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{bad","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"echo","args":"{\\"text\\":5}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Here is my answer.","delayMs":1}
            """)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done)
        #expect(r.text == "Here is my answer.")
        #expect(h.registry.invocations(of: "echo") == 0)
        let reqs = await h.controller.requests
        #expect(reqs.count == 3)
        #expect(reqs[1].toolChoice == .auto)  // the repair attempt may call again
        #expect(reqs[2].toolChoice == ToolChoice.none)  // then text only
        // The repair prompt carried the validation error back as the call's result.
        let repair = reqs[1].flattenedMessages.last { $0.role == .tool }
        #expect(repair?.toolCallID == "call_1")
        #expect(repair?.content.contains("not a JSON object") == true)
        #expect(try h.activities(a).map(\.state) == [.failed, .failed])
    }

    @Test func repairedCallRuns() async throws {
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{}","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"echo","args":"{\\"text\\":\\"fixed\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Done.","delayMs":1}
            """)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a)
        #expect(r.text == "Done.")
        #expect(h.registry.invocations(of: "echo") == 1)
        #expect(await h.controller.requests.map(\.toolChoice) == [.auto, .auto, .auto])
    }
}
