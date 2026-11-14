// M3 close review (docs/prd/reviews/M3-review.md): the app-side fixes — End and mute while connecting (P0-1, P1-1),
// read aloud stopped before it plays (P1-2), a spoken approval answered over the prompt (P1-5), a dictation whose
// window or controller goes away (P1-6), push-to-talk released when the window loses key (P2-7), and one mic holder
// app-wide (P2-5 / P2-8). The helper side of each: AntiChatEnginesTests/VoiceReviewFixTests.
//   make test-unit FILTER='VoiceSessionControllerTests|VoiceReviewAppTests'
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatHarness

extension VoiceRecordingEngine {
    var sessionStarts: [VoiceSessionStart] {
        lock.withLock { sentMessages.compactMap { if case .sessionStart(let s) = $0 { s } else { nil } } }
    }
    var controls: [VoiceSessionControl.Action] {
        lock.withLock { sentMessages.compactMap { if case .sessionControl(let c) = $0 { c.action } else { nil } } }
    }
    var cancelled: [UUID] { lock.withLock { cancels } }
}

/// In `VoiceSessionControllerTests` (serialized): these start calls, and calls are app-wide (`VoiceCalls.shared`).
extension VoiceSessionControllerTests {
    /// P0-1: End while the models register: the session is never opened and the request is cancelled.
    @Test func endWhileConnectingNeverOpensTheSession() async {
        let engine = VoiceRecordingEngine()
        engine.holdModels = true
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: FakeChatPort(), chatID: nil, voiceID: "", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.modelsCont != nil } }  // the models step is in flight
        let pump = c.currentPump
        c.end()
        #expect(c.phase == .idle)
        #expect(!VoiceCalls.shared.isActive)
        engine.releaseModels()
        await pump?.value
        #expect(engine.sessionStarts.isEmpty, "no session was opened after End")
        #expect(engine.cancelled.count == 1)
    }

    /// P0-1: End on an open session sends the End and cancels the request (whatever stage the helper is in).
    @Test func endOnAnOpenSessionEndsAndCancels() async {
        let engine = VoiceRecordingEngine()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: FakeChatPort(), chatID: nil, voiceID: "", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        let id = engine.sessionStarts.first?.requestID
        c.end()
        #expect(engine.lock.withLock { engine.sentMessages.contains { if case .sessionEnd(let e) = $0 { e.requestID == id } else { false } } })
        #expect(engine.cancelled == [id].compactMap { $0 })
    }

    /// P1-1: mutes pressed while connecting go out right behind `sessionStart`.
    @Test func muteWhileConnectingIsSentWhenTheSessionOpens() async {
        let engine = VoiceRecordingEngine()
        engine.holdModels = true
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: FakeChatPort(), chatID: nil, voiceID: "", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.modelsCont != nil } }
        c.toggleMic()
        c.toggleSpeaker()
        #expect(c.micMuted && c.speakerMuted)
        #expect(engine.controls.isEmpty, "nothing to address yet")
        engine.releaseModels()
        await Self.wait { engine.controls.count == 2 }
        let order = engine.lock.withLock { engine.sentMessages.map { m -> String in
            switch m {
            case .sessionStart: "start"
            case .sessionControl(let x): "\(x.action)"
            default: "other"
            }
        } }
        #expect(order.suffix(3) == ["start", "muteMic", "muteSpeaker"])
        c.end()
    }

    /// P2-7: Space held when the window lost key: the turn ends (`pttUp`), once.
    @Test func pushToTalkIsReleasedWhenTheWindowLosesKey() async {
        let engine = VoiceRecordingEngine()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: FakeChatPort(), chatID: nil, voiceID: "", rate: 1, mode: .pushToTalk, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        engine.emit([.voice(.voiceState(.listening))])
        await Self.wait { c.phase == .listening }
        c.pttDown()
        #expect(c.isPushToTalkHeld)
        c.releasePushToTalk()
        c.releasePushToTalk()
        #expect(engine.controls == [.pttDown, .pttUp])
        c.end()
    }

    /// P2-8: no dictation starts while a call holds the mic (the two would share the streaming EOU model).
    @Test func dictationDoesNotStartDuringACall() {
        let calls = VoiceCalls()
        let call = VoiceSessionController(engine: VoiceRecordingEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        call.setPreviewState(.listening)
        calls.current = call
        let d = DictationController(engine: VoiceRecordingEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil,
                                    tempDir: FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)"),
                                    calls: calls)
        d.start(incognito: true, chatID: nil)
        #expect(d.phase == .idle)
        #expect(calls.micInUse)
    }
}

@MainActor
@Suite(.serialized) struct VoiceReviewAppTests {
    static func wait(_ cond: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(cond())
    }

    static func dictation(_ engine: VoiceRecordingEngine, _ calls: VoiceCalls) -> DictationController {
        DictationController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil,
                            tempDir: FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)"),
                            calls: calls)
    }

    /// P1-6 + P2-5: a window closing mid-dictation cancels it in the helper; the registry follows the dictation.
    @Test func teardownCancelsTheDictation() async {
        let engine = VoiceRecordingEngine()
        let calls = VoiceCalls()
        let d = Self.dictation(engine, calls)
        d.start(incognito: true, chatID: nil)
        #expect(calls.isDictating, "the mic is held app-wide (Settings › Voice yields it)")
        await Self.wait { engine.lock.withLock { engine.dictationCont != nil } }
        let id = engine.lock.withLock { engine.sentMessages.compactMap { if case .dictationStart(let s) = $0 { s.requestID } else { nil } } }.first
        d.teardown()
        #expect(engine.cancelled == [id].compactMap { $0 })
        #expect(engine.lock.withLock { engine.sentMessages.contains { if case .dictationStop(let s) = $0 { s.mode == .cancel } else { false } } })
        #expect(!calls.isDictating)
    }

    /// P1-6: the controller is released mid-dictation: the next batch from the helper cancels the request.
    @Test func releasedControllerCancelsTheDictation() async {
        let engine = VoiceRecordingEngine()
        let calls = VoiceCalls()
        var d: DictationController? = Self.dictation(engine, calls)
        d?.start(incognito: true, chatID: nil)
        await Self.wait { engine.lock.withLock { engine.dictationCont != nil } }
        d = nil
        await Self.wait { !calls.isDictating }  // a released controller does not hold the mic
        engine.lock.withLock { engine.dictationCont }?.yield(EngineBatch(items: [.voice(.audioLevel(-30))]))
        await Self.wait { engine.cancelled.count == 1 }
    }

    /// P1-2: read aloud stopped while the models register: the speech is never opened, the request is cancelled.
    @Test func readAloudStoppedBeforeItPlaysIsNeverOpened() async {
        let engine = VoiceRecordingEngine()
        engine.holdModels = true
        let r = ReadAloudController()
        r.configure(engine: engine, models: { VoiceModelSet(slots: [:]) })
        r.toggle(id: "m1", text: "A long answer.")
        await Self.wait { engine.lock.withLock { engine.modelsCont != nil } }
        r.stop()
        #expect(r.speakingID == nil)
        engine.releaseModels()
        await Self.wait { engine.cancelled.count == 1 }
        // The models stream is done; the pump has returned without opening the speech.
        #expect(!engine.lock.withLock { engine.sentMessages.contains { if case .speak = $0 { true } else { false } } })
    }

    /// P1-5: the user answers over the spoken prompt (a barge-in on it): the reply waiting for the answer is not
    /// stopped, and the final transcript answers the card.
    @Test func answerOverThePromptIsNotAnInterruption() {
        let port = FakeChatPort()
        var sent: [VoiceSessionControl.Action] = []
        let b = VoiceTurnBridge { sent.append($0) }
        b.port = port
        b.approvalPrompt = { "\($0). Allow?" }
        b.replyStarted("a1")
        b.replyDelta("a1", "Saving it.")
        b.approvalChanged("a1", ToolApprovalRequest(id: "call_1", tool: "write_note", argumentsJSON: "{}", sideEffect: .write, untrusted: false))
        guard case .speak(_, let turn) = sent.first else { Issue.record("\(sent)"); return }
        b.handle(.ttsStopped(playedMs: 700, reason: .bargeIn))
        b.handle(.spokenSpan(turnID: turn, charOffset: 12))
        #expect(port.stops.isEmpty, "the reply waits for the answer")
        b.handle(.finalTranscript(FinalTranscript(text: "Allow once.", language: "en", engine: .parakeet)))
        #expect(port.approvals.map(\.answer) == [.allowOnce])
        #expect(port.sent.isEmpty)
    }
}
