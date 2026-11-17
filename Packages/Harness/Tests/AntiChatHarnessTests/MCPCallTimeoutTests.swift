// A connected-app / MCP call that never answers ends with a plain error after MCPTools.callTimeout instead of holding
// the turn for good (no timeout bounded a call, and the stall watchdog does not watch tool runs).
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct MCPCallTimeoutTests {
    @Test func aCallThatNeverAnswersFailsWithAPlainLine() async throws {
        let started = ContinuousClock.now
        do {
            // A body that ignores cancellation, like a server that never writes its reply.
            _ = try await MCPTools.bounded(.milliseconds(80), server: "Gmail") { () -> String in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
                }
                return "late"
            }
            Issue.record("the call was not stopped")
        } catch let e as ToolRunError {
            #expect(e.message.hasPrefix("Gmail did not answer within") && e.message.contains("try again"))
        }
        #expect(ContinuousClock.now - started < .seconds(2), "the hung call is not waited for")
    }

    @Test func anAnswerInTimeAndItsErrorsPassThrough() async throws {
        #expect(try await MCPTools.bounded(.seconds(5), server: "Gmail") { "ok" } == "ok")
        await #expect(throws: ToolRunError.self) {
            _ = try await MCPTools.bounded(.seconds(5), server: "Gmail") { () -> String in throw ToolRunError("boom") }
        }
        #expect(MCPTools.callTimeout >= .seconds(60))
    }

    @Test func stopCancelsTheCall() async throws {
        let t = Task { try await MCPTools.bounded(.seconds(30), server: "Gmail") { () -> String in
            try await Task.sleep(for: .seconds(30)); return "late"
        } }
        try await Task.sleep(for: .milliseconds(50))
        t.cancel()
        await #expect(throws: (any Error).self) { _ = try await t.value }
    }
}
