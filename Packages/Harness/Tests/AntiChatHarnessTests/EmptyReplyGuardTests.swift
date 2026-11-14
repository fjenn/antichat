// Soak dry run 2 (build/soak/20261112T034152Z): replies that ended `done` with no text, no parts and no usage. The
// root cause there was the router (an install card in place of the answer; InstallCardPolicyTests
// .soakPromptsGetAnAnswerNotACard). This suite is the general guard behind it: whatever the engine stream does — EOS or a
// stop sequence right away, whitespace only, a thinking block that used the whole budget — a turn never ends as a
// silent empty `done`. It fails as `engine.emptyReply` (ErrorInline + Retry), or, with reasoning to keep, ends
// interrupted with that code (notice + Retry). A card, a tool step or real text is not an empty reply.
//   make test-unit FILTER=EmptyReplyGuardTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct EmptyReplyGuardTests {
    static let code = AntiChatError.Code.engineEmptyReply.rawValue

    private func run(_ script: String) async throws -> (Harness, String, TurnResult) {
        let h = try Harness(script: script)
        let (_, a) = await h.send("Suggest a name for a small bakery that sells sourdough.")
        return (h, a, try await h.log.waitFinished(a))
    }

    /// EOS at once (the chat template's stop token first, or a stop sequence on the first token): no event but `done`.
    @Test func immediateStopFailsWithRetry() async throws {
        let (h, a, r) = try await run(#"{"t":"done","reason":"stop"}"#)
        #expect(r.status == .error && r.errorCode == Self.code && r.text.isEmpty, "\(r.status) \(String(describing: r.errorCode))")
        let row = try #require(try h.message(a))
        #expect(row.status == .error && row.errorCode == Self.code)
        #expect(AntiChatError.Code.engineEmptyReply.defaultRecovery == [.retry])
        #expect(AntiChatError.Code.engineEmptyReply.userMessageKey == "engine.emptyReply")
    }

    /// Usage arrives (the engine generated tokens) but nothing visible: whitespace / newlines only.
    @Test func whitespaceOnlyFails() async throws {
        let (_, _, r) = try await run("""
            {"t":"textDelta","v":"\\n\\n","delayMs":1}
            {"t":"textDelta","v":"  ","delayMs":1}
            {"t":"usage","prompt":40,"completion":3}
            {"t":"done","reason":"stop"}
            """)
        #expect(r.status == .error && r.errorCode == Self.code, "\(r.status) \(String(describing: r.errorCode))")
    }

    /// A thinking-only reply (the reasoning used the output limit, or the template ended the turn after `</think>`):
    /// the reasoning is kept, the turn ends interrupted with the code, so the notice offers Retry.
    @Test func reasoningOnlyKeepsTheThoughtsAndOffersRetry() async throws {
        let (h, a, r) = try await run("""
            {"t":"reasoningDelta","v":"Let me think about bakery names","delayMs":1}
            {"t":"reasoningDelta","v":" with a sourdough pun…","delayMs":1}
            {"t":"done","reason":"length"}
            """)
        #expect(r.status == .interrupted && r.errorCode == Self.code, "\(r.status) \(String(describing: r.errorCode))")
        #expect(r.text.isEmpty && r.reasoning.hasPrefix("Let me think"))
        let parts = try MessageRepository(h.database).parts(of: a)
        #expect(parts.contains { $0.kind == .reasoning && !$0.body.isEmpty })
        #expect(try h.message(a)?.status == .interrupted)
    }

    /// A normal answer (also after reasoning) is untouched.
    @Test func answersStayDone() async throws {
        let (_, _, plain) = try await run(#"{"t":"textDelta","v":"Rise & Crumb","delayMs":1}"#)
        #expect(plain.status == .done && plain.errorCode == nil && plain.text == "Rise & Crumb")
        let (_, _, thought) = try await run("""
            {"t":"reasoningDelta","v":"hm","delayMs":1}
            {"t":"textDelta","v":"Crust & Co.","delayMs":1}
            """)
        #expect(thought.status == .done && thought.errorCode == nil && thought.text == "Crust & Co.")
    }

    /// Stop before anything arrived stays an interrupted turn (the user's own action), never `engine.emptyReply`.
    @Test func stopIsNotAnEmptyReply() async throws {
        let h = try Harness(script: """
            {"t":"wait","ms":60000}
            {"t":"textDelta","v":"late","delayMs":1}
            """)
        let (_, a) = await h.send("hi")
        try await Task.sleep(for: .milliseconds(50))
        await h.controller.stop()
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .interrupted && r.errorCode == nil, "\(r.status) \(String(describing: r.errorCode))")
    }

    /// The pure rule: what counts as "nothing for the user".
    @Test func decisionTable() {
        func empty(stopped: Bool = false, finish: FinishReason? = .stop, error: String? = nil, text: String = "",
                   parts: [PartContent] = [], steps: Int = 0, card: Bool = false, media: Bool = false) -> Bool {
            TurnController.isEmptyAnswer(stopped: stopped, finish: finish, errorCode: error, text: text, parts: parts,
                                         toolSteps: steps, cardShown: card, mediaMade: media)
        }
        #expect(empty())
        #expect(empty(text: " \n"))
        #expect(empty(finish: .length, parts: [PartContent(kind: .reasoning, body: "…")]))
        #expect(empty(parts: [PartContent(kind: .activity, body: "{}")]))  // a notice alone is not an answer
        #expect(!empty(text: "Hi"))
        #expect(!empty(stopped: true))
        #expect(!empty(finish: .cancelled))
        #expect(!empty(error: "engine.restarted"))  // already a failure with its own code
        #expect(!empty(steps: 1))                   // tools ran (their cards are the reply)
        #expect(!empty(card: true))                 // the install card is the reply
        #expect(!empty(media: true))
        #expect(!empty(parts: [PartContent(kind: .toolCall, body: "{}")]))
        #expect(!empty(parts: [PartContent(kind: .image, body: "x")]))
    }
}
