// The output budget and the two limits that used to end a reply silently:
//   - answers were capped at a flat 1,024 tokens and a cut (`done(length)`) was stored as a finished reply;
//   - at the step limit the turn ended with tool lines and [Continue] but no answer.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct OutputLimitTests {
    @Test(arguments: [
        (8192, 1000, 0, 2048),      // T0 starter models (8K): a quarter of the window
        (16_384, 1000, 0, 4096),    // T1–T4 (16K)
        (32_768, 1000, 0, 4096),    // never above the ceiling
        (16_384, 14_000, 0, 2128),  // what the prompt leaves, minus the margin
        (16_384, 15_500, 0, 1024),  // never below the old flat value
        (16_384, 2000, 4096, 4096), // thinking is taken out of the room first; here there is plenty
        (8192, 3000, 4096, 1024),   // 8K with Think harder: the floor
    ])
    func answerBudget(window: Int, prompt: Int, reasoning: Int, want: Int) {
        #expect(OutputBudget.answerTokens(window: window, promptTokens: prompt, reasoning: reasoning) == want)
    }

    @Test func aPlainTurnGetsTheWindowsBudgetNotTheFlatDefault() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"Hi.","delayMs":1}"#)
        let (_, a) = await h.send()
        _ = try await h.log.waitFinished(a)
        #expect(await h.controller.requests[0].sampling.maxTokens == 4096)  // the scripted slot's window is 16K
    }

    static let cut = [#"{"t":"textDelta","v":"The quick brown","delayMs":1}"# + "\n" + #"{"t":"done","reason":"length"}"#,
                      #"{"t":"textDelta","v":"fox jumps.","delayMs":1}"#].joined(separator: "\n{\"t\":\"turn\"}\n")

    @Test func aCutAnswerOffersContinueAndCarriesOnInTheSameReply() async throws {
        let h = try ToolLoopHarness(script: Self.cut)
        let (_, a) = await h.send("Tell me a long story")
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done && r.text == "The quick brown")
        let notice = try #require(try h.activities(a).last)
        #expect(notice.isLengthLimit && notice.offersContinue, "the cut is not silent: Continue shows")

        await h.controller.start(.continueTools(assistantID: a), assistantID: a)
        try await h.log.wait { log in
            log.all.filter { if case .finished = $0.kind { $0.assistantID == a } else { false } }.count == 2
        }
        // One reply, joined with a single space (no paragraph break in the middle of the sentence).
        #expect(try h.parts(a, .text).map(\.body) == ["The quick brown fox jumps."])
        #expect(try MessageRepository(h.database).message(a)?.status == .done)
        #expect(try h.activities(a).contains { $0.offersContinue } == false, "the pressed notice is spent")
        // The model saw its own text so far and was asked to carry on; no tool may be called on that step.
        let req = try #require(await h.controller.requests.first)
        let tail = req.flattenedMessages.suffix(2)
        #expect(tail.first?.role == .assistant && tail.first?.content == "The quick brown")
        #expect(tail.last?.role == .user && tail.last?.content.contains("cut off at the length limit") == true)
        #expect(req.toolChoice == ToolChoice.none)
        // The streamed deltas of the continuation start with the joining space.
        let deltas = h.log.all.compactMap { u -> String? in if case .textDelta(let s) = u.kind { s } else { nil } }
        #expect(deltas.joined() == "The quick brown fox jumps.")
    }

    @Test func anAnswerThatEndedByItselfHasNoNotice() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"Done.","delayMs":1}"#)
        let (_, a) = await h.send()
        _ = try await h.log.waitFinished(a)
        #expect(try h.activities(a).isEmpty)
    }

    @Test func joinAddsOneSpaceOnlyWhereNeeded() {
        #expect(TurnController.lengthJoin("the quick", "brown") == " ")
        #expect(TurnController.lengthJoin("the quick ", "brown") == "")
        #expect(TurnController.lengthJoin("the quick", " brown") == "")
        #expect(TurnController.lengthJoin("the quick", ", brown") == "")
        #expect(TurnController.lengthJoin("line\n", "next") == "")
        #expect(TurnController.lengthJoin("", "next") == "")
    }

    /// T0: three tool steps, then the model must say what it did (text only), and Continue stays offered.
    @Test func theStepLimitEndsWithAnAnswerAndContinue() async throws {
        let call = { (n: Int) in
            #"{"t":"toolCallDone","id":"call_\#(n)","name":"echo","args":"{\"text\":\"step \#(n)\"}","delayMs":1}"#
        }
        let script = ([1, 2, 3].map(call) + [#"{"t":"textDelta","v":"I checked three things; two are left.","delayMs":1}"#])
            .joined(separator: "\n{\"t\":\"turn\"}\n")
        let h = try ToolLoopHarness(script: script, tier: .t0)
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a, timeout: .seconds(20))
        #expect(r.status == .done && r.text == "I checked three things; two are left.")
        let reqs = await h.controller.requests
        #expect(reqs.count == 4 && h.registry.invocations(of: "echo") == 3)
        #expect(reqs[3].toolChoice == ToolChoice.none)
        #expect(reqs[3].flattenedMessages.last?.content.hasPrefix(TurnController.stepLimitPrompt) == true)
        let last = try #require(try h.activities(a).last)
        #expect(last.isLoopLimit && !last.isLengthLimit && last.offersContinue && last.steps == 3)
    }
}
