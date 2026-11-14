// M3.T13 AT-057 (R-057), in-process legs: a voice turn runs tools exactly like a typed turn (ActivityLine, results in
// the thread); a turn that made a picture / video / file ends with the spoken pointer (stored and spoken); an
// ApprovalCard is said aloud and a spoken "allow once" / "always allow" / "deny" answers it. The XCUITest legs
// (`App/UITests/VoiceToolsTests.swift`) are pending (Q-015).
//   make test-unit FILTER=VoiceToolsTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A stand-in media tool: succeeds, says what it made (a picture / clip tool answers with its `done` outcome).
func standInTool(_ name: String, sideEffect: ToolSideEffect = .read, result: String? = nil) -> RegisteredTool {
    let out = result ?? {
        switch name {
        case "create_image": ImageTurnPolicy.Outcome.done(imageID: "img-1", width: 8, height: 8).resultJSON
        case "create_video": VideoTurnPolicy.Outcome.done(videoID: "vid-1", path: nil, poster: nil).resultJSON
        default: "Queued: \(name)."
        }
    }()
    return RegisteredTool(name: name, description: "stand-in \(name)",
                          parametersJSON: #"{"properties":{"prompt":{"type":"string"}},"type":"object"}"#,
                          sideEffect: sideEffect, outputIsUntrusted: false) { _ in out }
}

@Suite("VoiceToolsTests") struct VoiceToolsTests {
    static let sentences: [SpokenSummary.Medium: String] = [
        .picture: "I've made the picture, it's in the chat", .video: "I've made the video, it's in the chat",
        .file: "I've made the file, it's in the chat",
    ]

    static func script(_ tool: String) -> String {
        """
        {"t":"toolCallDone","id":"call_1","name":"\(tool)","args":"{\\"prompt\\":\\"a red fox\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Here you go.","delayMs":1}
        """
    }

    @Test(arguments: [("create_image", "I've made the picture, it's in the chat"),
                      ("create_video", "I've made the video, it's in the chat"),
                      ("create_file", "I've made the file, it's in the chat")])
    func aVoiceTurnThatMadeMediaSaysWhereItIs(tool: String, pointer: String) async throws {
        let h = try ToolLoopHarness(script: Self.script(tool), tier: .t3, tools: [standInTool(tool)])
        await h.controller.setSpokenPointers(Self.sentences)
        let (_, a) = await h.send("make me a red fox")
        let r = try await h.log.waitFinished(a, timeout: .seconds(20))
        #expect(r.status == .done)
        #expect(r.text == "Here you go.\n\n" + pointer, "spoken (the last delta) and shown")
        let stored = try h.parts(a, .text).map(\.body).joined()
        #expect(stored.hasSuffix(pointer), "stored with the reply")
        #expect(try h.activities(a).contains { $0.tool == tool && $0.state == .done }, "the ActivityLine as in typed turns")
    }

    @Test func aTypedTurnOrAFailedToolHasNoPointer() async throws {
        let typed = try ToolLoopHarness(script: Self.script("create_image"), tier: .t3, tools: [standInTool("create_image")])
        let (_, a) = await typed.send("make me a red fox")
        #expect(try await typed.log.waitFinished(a, timeout: .seconds(20)).text == "Here you go.")
        let failing = RegisteredTool(name: "create_image", description: "x", sideEffect: .read) { _ in throw ToolRunError("no pack") }
        let h = try ToolLoopHarness(script: Self.script("create_image"), tools: [failing])
        await h.controller.setSpokenPointers(Self.sentences)
        let (_, b) = await h.send("make me a red fox")
        #expect(try await h.log.waitFinished(b, timeout: .seconds(20)).text == "Here you go.")
    }

    /// M9 review H4: the pointer is spoken only for media that was made and allowed. A safety block, a cancelled plan
    /// card or job, and a failed or unavailable job end `done` as a call, but put nothing in the chat.
    @Test(arguments: [
        ("create_image", ImageTurnPolicy.Outcome.notShown.resultJSON),
        ("create_image", ImageTurnPolicy.Outcome.failed(code: "cancelled").resultJSON),
        ("create_image", ImageTurnPolicy.Outcome.failed(code: "failed").resultJSON),
        ("create_image", ImageTurnPolicy.Outcome.unavailable.resultJSON),
        ("create_image", ImageTurnPolicy.Outcome.safetyMissing(sizeBytes: 1).resultJSON),
        ("create_video", VideoTurnPolicy.Outcome.notShown.resultJSON),
        ("create_video", VideoTurnPolicy.Outcome.notStarted.resultJSON),
        ("create_video", VideoTurnPolicy.Outcome.failed(code: "cancelled").resultJSON),
        ("create_video", VideoTurnPolicy.Outcome.failed(code: "interrupted").resultJSON),
    ])
    func noPointerWhenNoMediaWasMade(tool: String, result: String) async throws {
        let h = try ToolLoopHarness(script: Self.script(tool), tier: .t3, tools: [standInTool(tool, result: result)])
        await h.controller.setSpokenPointers(Self.sentences)
        let (_, a) = await h.send("make me a red fox")
        let r = try await h.log.waitFinished(a, timeout: .seconds(20))
        #expect(r.text == "Here you go.", "\(tool) \(result): no pointer")
        #expect(SpokenSummary.medium(forTool: tool, result: result) == nil)
    }

    @Test func mediumFollowsTheOutcome() {
        #expect(SpokenSummary.medium(forTool: "create_image",
                                     result: ImageTurnPolicy.Outcome.done(imageID: "i", width: nil, height: nil).resultJSON) == .picture)
        #expect(SpokenSummary.medium(forTool: "create_video",
                                     result: VideoTurnPolicy.Outcome.done(videoID: "v", path: nil, poster: nil).resultJSON) == .video)
        #expect(SpokenSummary.medium(forTool: "create_image", result: "not json") == nil)
        #expect(SpokenSummary.medium(forTool: "create_file", result: "Saved report.docx") == .file)
        #expect(SpokenSummary.medium(forTool: "get_time", result: "12:00") == nil)
    }

    @Test func spokenApprovalKeywords() {
        #expect(VoiceToolPolicy.approvalAnswer("Allow once.") == .allowOnce)
        #expect(VoiceToolPolicy.approvalAnswer("Yes.") == .allowOnce)
        #expect(VoiceToolPolicy.approvalAnswer("Always allow!") == .always)
        #expect(VoiceToolPolicy.approvalAnswer("Deny.") == .deny)
        #expect(VoiceToolPolicy.approvalAnswer("No.") == .deny)
        #expect(VoiceToolPolicy.approvalAnswer("Don't allow that.") == .deny)
        #expect(VoiceToolPolicy.approvalAnswer("Tell me about the weather in Paris tomorrow please.") == nil)
        #expect(VoiceToolPolicy.approvalAnswer("What is the capital of Norway?") == nil)
        // Review finding 1: negations and other words never approve.
        for t in ["I wouldn't allow that.", "Never allow it.", "Not allow.", "Can't allow this.", "Allow? No.", "Thanks.",
                  "Don't always allow it."] {
            #expect(VoiceToolPolicy.approvalAnswer(t) != .allowOnce && VoiceToolPolicy.approvalAnswer(t) != .always, "\(t)")
        }
        #expect(VoiceToolPolicy.approvalAnswer("Okay.") == .allowOnce)
        #expect(VoiceToolPolicy.approvalAnswer("Yes, please.") == .allowOnce)
        #expect(VoiceToolPolicy.approvalAnswer("No, thanks.") == .deny)
        #expect(VoiceToolPolicy.spokenAction(tool: "write_note") == "Write note")
    }

    @MainActor @Test func anApprovalIsSpokenAndAnsweredByVoice() async throws {
        var sent: [VoiceSessionControl.Action] = []
        let port = FakeChatPort()
        let b = VoiceTurnBridge { sent.append($0) }
        b.port = port
        b.approvalPrompt = { "\($0). Allow?" }
        b.replyStarted("a1")
        b.replyDelta("a1", "Saving it.")
        b.approvalChanged("a1", ToolApprovalRequest(id: "call_1", tool: "write_note", argumentsJSON: "{}", sideEffect: .write, untrusted: false))
        let spoken = sent.compactMap { a -> String? in if case .speak(let t, _) = a { t } else { nil } }.joined()
        #expect(spoken.contains("Write note. Allow?"), "\(spoken)")
        // M3 review P1-5: the prompt ends the spoken segment, so the helper listens for the answer (no barge-in).
        guard case .speak(_, let first) = sent.first, case .speakEnd(let ended) = sent.last else { Issue.record("\(sent)"); return }
        #expect(ended == first)
        b.handle(.finalTranscript(FinalTranscript(text: "Allow once.", language: "en", engine: .parakeet)))
        #expect(port.approvals.count == 1 && port.approvals.first?.answer == .allowOnce)
        #expect(port.sent.isEmpty, "the answer is not a chat message")
        // A barge-in after the prompt stores only the reply's own text (the prompt is not part of it): the text after
        // the approval is a new spoken segment, whose offsets continue after what the first segment stored.
        b.replyDelta("a1", " Done.")
        guard case .speak(_, let turn) = sent.last! else { Issue.record("no speak"); return }
        #expect(turn != first, "a new segment")
        b.handle(.ttsStopped(playedMs: 900, reason: .bargeIn))
        b.handle(.spokenSpan(turnID: turn, charOffset: 3))
        #expect(port.stops.last?.1 == "Saving it.".utf16.count + 3)
    }
}
