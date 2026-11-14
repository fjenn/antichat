// M3.T10 step 2 / M3.T11 step 6: the voice bridge (helper events ↔ the chat) and the app-side session controller:
// a final transcript becomes a user message, reply deltas are spoken in order, a barge-in stops the reply with the
// spoken span, late deltas of a cancelled reply are dropped, an empty session writes nothing, the call indicator state
// follows the session, and push-to-talk sends down / up.
//   make test-unit FILTER='VoiceTurnBridgeTests|VoiceSessionControllerTests'
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatHarness

@MainActor
final class FakeChatPort: VoiceChatPort {
    var sent: [String] = []
    var stops: [(String, Int?)] = []
    func sendUserText(_ text: String) -> Bool { sent.append(text); return true }
    func stopReply(_ assistantID: String, keepingUTF16: Int?) { stops.append((assistantID, keepingUTF16)) }
    var approvals: [(assistantID: String, callID: String, answer: ApprovalAnswer)] = []
    func answerApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer) {
        approvals.append((assistantID, callID, answer))
    }
}

@MainActor
@Suite struct VoiceTurnBridgeTests {
    @Test func finalTranscriptBecomesAUserMessage() {
        let port = FakeChatPort()
        let b = VoiceTurnBridge { _ in }
        b.port = port
        b.handle(.finalTranscript(FinalTranscript(text: "  what time is it ", language: "en", engine: .parakeet)))
        b.handle(.finalTranscript(FinalTranscript(text: " ", language: "en", engine: .parakeet)))
        #expect(port.sent == ["what time is it"])
    }

    @Test func repliesAreSpokenInOrderAndEnd() {
        var actions: [VoiceSessionControl.Action] = []
        let b = VoiceTurnBridge { actions.append($0) }
        b.replyStarted("a1")
        b.replyDelta("a1", "Hello ")
        b.replyDelta("a1", "there.")
        b.replyFinished("a1")
        guard case .speak(_, let turn) = actions.first else { Issue.record("\(actions)"); return }
        #expect(actions == [.speak(text: "Hello ", turnID: turn), .speak(text: "there.", turnID: turn), .speakEnd(turnID: turn)])
    }

    @Test func bargeInStopsTheReplyAtTheSpokenSpanAndDropsLateDeltas() {
        let port = FakeChatPort()
        var actions: [VoiceSessionControl.Action] = []
        let b = VoiceTurnBridge { actions.append($0) }
        b.port = port
        b.replyStarted("a1")
        b.replyDelta("a1", "It is sunny today. ")
        guard case .speak(_, let turn) = actions.first else { Issue.record("no speak"); return }
        b.handle(.ttsStopped(playedMs: 900, reason: .bargeIn))
        b.handle(.spokenSpan(turnID: turn, charOffset: 5))
        #expect(port.stops.count == 1)
        #expect(port.stops.first?.0 == "a1" && port.stops.first?.1 == 5)
        let before = actions.count
        b.replyDelta("a1", "More text.")
        b.replyFinished("a1")
        #expect(actions.count == before, "nothing more of a cancelled reply reaches the helper")
    }

    @Test func bargeInBeforeAnyTextStopsWithNothingHeard() {
        let port = FakeChatPort()
        let b = VoiceTurnBridge { _ in }
        b.port = port
        b.replyStarted("a2")
        b.handle(.ttsStopped(playedMs: 0, reason: .bargeIn))
        #expect(port.stops.count == 1 && port.stops.first?.1 == 0)
    }

    @Test func naturalEndStopsNothing() {
        let port = FakeChatPort()
        var turn: UUID?
        let b = VoiceTurnBridge { if case .speak(_, let t) = $0 { turn = t } }
        b.port = port
        b.replyDelta("a1", "Hi.")
        b.replyFinished("a1")
        b.handle(.ttsStopped(playedMs: 400, reason: .finished))
        b.handle(.spokenSpan(turnID: turn!, charOffset: 3))
        #expect(port.stops.isEmpty)
    }
}

/// Records voice messages; session streams stay open until ended.
final class VoiceRecordingEngine: EngineService, @unchecked Sendable {
    let lock = NSLock()
    var sentMessages: [VoiceMessage] = []
    var sessionCont: AsyncStream<EngineBatch>.Continuation?
    /// M3 review: requests cancelled; `holdModels` keeps the models step open until `releaseModels`.
    var cancels: [UUID] = []
    var holdModels = false
    var modelsCont: AsyncStream<EngineBatch>.Continuation?
    var dictationCont: AsyncStream<EngineBatch>.Continuation?
    func releaseModels() { lock.withLock { modelsCont }?.finish() }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) { lock.withLock { cancels.append(requestID) } }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> {
        lock.withLock { sentMessages.append(message) }
        if case .sessionStart = message {
            let (s, c) = AsyncStream<EngineBatch>.makeStream()
            lock.withLock { sessionCont = c }
            return s
        }
        if case .dictationStart = message {
            let (s, c) = AsyncStream<EngineBatch>.makeStream()
            lock.withLock { dictationCont = c }
            return s
        }
        if case .models = message, lock.withLock({ holdModels }) {
            let (s, c) = AsyncStream<EngineBatch>.makeStream()
            lock.withLock { modelsCont = c }
            return s
        }
        return AsyncStream { $0.finish() }
    }

    func voiceSend(_ message: VoiceMessage) -> Bool {
        lock.withLock { sentMessages.append(message) }
        if case .sessionEnd = message { lock.withLock { sessionCont }?.finish() }
        return true
    }

    func emit(_ items: [StreamItem]) { lock.withLock { sessionCont }?.yield(EngineBatch(items: items)) }
}

@MainActor
@Suite(.serialized) struct VoiceSessionControllerTests {
    static func wait(_ cond: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func sessionStatesIndicatorAndEmptySessionWritesNothing() async {
        let engine = VoiceRecordingEngine()
        let port = FakeChatPort()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        #expect(!VoiceCalls.shared.isActive)
        c.start(port: port, chatID: nil, voiceID: "af_heart", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        #expect(c.phase == .connecting)
        #expect(VoiceCalls.shared.isActive, "the menu bar indicator is inserted when the call starts")
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        engine.emit([.voice(.voiceState(.listening)), .voice(.audioLevel(-30))])
        await Self.wait { c.phase == .listening }
        #expect(c.inputLevel == -30)
        engine.emit([.voice(.voiceState(.transcribing)), .voice(.partialTranscript("hel"))])
        await Self.wait { c.caption == "hel" }
        #expect(c.phase == .userSpeaking)
        c.end()
        #expect(c.phase == .idle)
        #expect(!VoiceCalls.shared.isActive, "removed after End")
        #expect(port.sent.isEmpty, "no utterance: nothing is written to the chat")
        let start = engine.lock.withLock { engine.sentMessages.compactMap { m -> VoiceSessionStart? in
            if case .sessionStart(let s) = m { s } else { nil } } }.first
        #expect(start?.mode == .handsFree)
    }

    @Test func bargeInSnapsToListeningAndCaptionsFollowSpeech() async {
        let engine = VoiceRecordingEngine()
        let port = FakeChatPort()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: port, chatID: "c1", voiceID: "", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: "tell me", language: "en", engine: .parakeet))),
                     .voice(.voiceState(.thinking))])
        await Self.wait { port.sent == ["tell me"] }
        engine.emit([.voice(.voiceState(.speaking)), .voice(.ttsStarted(chunkIndex: 0)), .voice(.speakingText("Once upon a time,"))])
        await Self.wait { c.caption == "Once upon a time," }
        #expect(c.phase == .speaking)
        // Q-015 r7 (R-052 AC5): the sentence's next chunk adds to the caption; the next sentence starts it afresh.
        engine.emit([.voice(.ttsStarted(chunkIndex: 1)), .voice(.speakingText("there was a fox."))])
        await Self.wait { c.caption == "Once upon a time, there was a fox." }
        #expect(c.caption == "Once upon a time, there was a fox.")
        engine.emit([.voice(.ttsStarted(chunkIndex: 2)), .voice(.speakingText("The end."))])
        await Self.wait { c.caption == "The end." }
        #expect(c.caption == "The end.")
        engine.emit([.voice(.ttsStopped(playedMs: 500, reason: .bargeIn))])
        await Self.wait { c.bargeIns == 1 }
        #expect(c.phase == .userSpeaking, "the orb snaps in the same update as ttsStopped")
        c.end()
    }

    /// F3 (round 66, vq-m3 voice-live-thinking): the reply's text is held while the session thinks and shows once
    /// speaking starts (the bar and the transcript change together); a barge-in or a reply with no audio shows it too.
    @Test func replyTextIsHeldUntilSpeakingStarts() async {
        let engine = VoiceRecordingEngine()
        let port = FakeChatPort()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: port, chatID: "c1", voiceID: "", rate: 1, mode: .handsFree, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: "shoes?", language: "en", engine: .parakeet))),
                     .voice(.voiceState(.thinking))])
        await Self.wait { c.phase == .thinking }
        c.bridge.replyStarted("a1")
        c.bridge.replyDelta("a1", "Comfortable walking shoes.")
        c.bridge.replyFinished("a1")  // the model is done long before the first audio
        #expect(c.holdsReply("a1"), "thinking: the written reply is not shown yet")
        #expect(!c.holdsReply("other"))
        engine.emit([.voice(.voiceState(.speaking)), .voice(.ttsStarted(chunkIndex: 0))])
        await Self.wait { c.phase == .speaking }
        #expect(!c.holdsReply("a1"), "speaking: the reply shows")
        engine.emit([.voice(.voiceState(.listening))])
        await Self.wait { c.phase == .listening }
        // The next turn: the previous reply is never held again; a reply with no audio shows when thinking ends.
        engine.emit([.voice(.voiceState(.thinking))])
        await Self.wait { c.phase == .thinking }
        #expect(!c.holdsReply("a1"))
        c.bridge.replyStarted("a2")
        #expect(c.holdsReply("a2"))
        engine.emit([.voice(.voiceState(.listening))])
        await Self.wait { c.phase == .listening }
        #expect(!c.holdsReply("a2"))
        c.end()
        #expect(c.voicedReplyID == nil)
    }

    @Test func pushToTalkSendsDownAndUp() async {
        let engine = VoiceRecordingEngine()
        let c = VoiceSessionController(engine: engine, models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil, tier: .t3)
        c.start(port: FakeChatPort(), chatID: nil, voiceID: "", rate: 1, mode: .pushToTalk, locale: nil, codeOmitted: nil)
        await Self.wait { engine.lock.withLock { engine.sessionCont != nil } }
        engine.emit([.voice(.voiceState(.listening))])
        await Self.wait { c.phase == .listening }
        c.pttDown()
        c.pttDown()  // key repeat: one down
        c.pttUp()
        let actions = engine.lock.withLock { engine.sentMessages.compactMap { m -> VoiceSessionControl.Action? in
            if case .sessionControl(let s) = m { s.action } else { nil } } }
        #expect(actions == [.pttDown, .pttUp])
        c.end()
    }
}

@Suite(.serialized) struct VoiceContextCapTests {
    @Test func t1VoiceSessionCapsTheChatWindowAt8K() {
        let slot = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/m", footprintBytes: 1)
        // The pure form (the process-wide cap is set only by a T1 call; other suites run in parallel).
        #expect(ContextPolicy.standard.window(for: slot, cap: nil) == 16_384)
        #expect(ContextPolicy.standard.window(for: slot, cap: 8192) == 8192)
        #expect(ContextPolicy.standard.window(for: ModelSlot(engine: .mlx, key: "chat-2b", path: "/m", footprintBytes: 1), cap: 8192) == 8192)
    }
}
