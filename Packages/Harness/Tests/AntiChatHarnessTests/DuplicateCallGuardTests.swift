// M1.T16 AT-232 (2): a repeated identical call (same name, same canonical arguments) in one turn is executed once
// (tool invocation counter = 1); the repeat gets the duplicate notice and the next step is the text-only last one.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("DuplicateCallGuardTests") struct DuplicateCallGuardTests {
    @Test func canonicalArgumentsIgnoreKeyOrderAndSpacing() {
        var g = DuplicateCallGuard()
        let first = g.admit(name: "echo", argumentsJSON: #"{"a":1,"b":"x"}"#)
        let reordered = g.admit(name: "echo", argumentsJSON: #"{ "b": "x", "a": 1 }"#)
        let otherArgs = g.admit(name: "echo", argumentsJSON: #"{"a":2,"b":"x"}"#)
        let otherName = g.admit(name: "other", argumentsJSON: #"{"a":1,"b":"x"}"#)
        #expect(first && !reordered && otherArgs && otherName)
        #expect(g.skipped == 1)
        #expect(DuplicateCallGuard.canonical("not json ") == "not json")
    }

    @Test func repeatedIdenticalCallRunsOnce() async throws {
        // Every step calls echo with the same arguments (fresh call ids).
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_{{n}}","name":"echo","args":"{\\"text\\":\\"same\\"}","delayMs":1}
            """)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a, timeout: .seconds(10))
        #expect(r.status == .done)
        #expect(h.registry.invocations(of: "echo") == 1)
        let reqs = await h.controller.requests
        // Step 1 runs it, step 2's repeat is skipped, step 3 is text-only: the loop ends one step after the repeat.
        #expect(reqs.count == 3)
        #expect(reqs.last?.toolChoice == ToolChoice.none)
        let acts = try h.activities(a)
        #expect(acts.map(\.state) == [.done, .skipped])
        let results = try h.parts(a, .toolResult)
        #expect(results.count == 2)
        #expect(results.last?.body.contains("Duplicate call skipped") == true)
        // The text-only step's own call is neither run nor stored.
        #expect(try h.parts(a, .toolCall).count == 2)
    }

    /// Q-015 XCUITest catch-up: engines restart call ids per step, so the repeat arrives as "call_1" again. Its
    /// skipped line must not replace the first call's line (which carries that call's media card).
    @Test func repeatWithAReusedCallIDKeepsBothLines() async throws {
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{\\"text\\":\\"same\\"}","delayMs":1}
            """)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a, timeout: .seconds(10))
        #expect(r.status == .done)
        #expect(h.registry.invocations(of: "echo") == 1)
        let acts = try h.activities(a)
        #expect(acts.map(\.state) == [.done, .skipped])
        #expect(acts.map(\.id) == ["call_1", "call_1#2"])
    }

    @Test func uniqueActivityKey() {
        #expect(TurnController.uniqueActivityKey("call_1", taken: []) == "call_1")
        #expect(TurnController.uniqueActivityKey("call_1", taken: ["call_1"]) == "call_1#2")
        #expect(TurnController.uniqueActivityKey("call_1", taken: ["call_1", "call_1#2"]) == "call_1#3")
    }
}
