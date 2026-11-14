import AntiChatEngineProtocol
import Foundation
import SpeechSwiftVendored
import Synchronization
import Testing
@testable import AntiChatEngines

private final class SequenceVAD: StreamingVADProvider, @unchecked Sendable {
    let inputSampleRate = 16_000
    let chunkSize = 512
    var probabilities: [Float]
    var index = 0

    init(_ probabilities: [Float]) { self.probabilities = probabilities }
    func processChunk(_ samples: [Float]) -> Float {
        defer { index += 1 }
        return index < probabilities.count ? probabilities[index] : 0
    }
    func resetState() {}
}

private final class StubTurn: TurnCompletionProvider, @unchecked Sendable {
    let probability: Float
    private(set) var calls = 0
    init(_ probability: Float) { self.probability = probability }
    func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float {
        calls += 1
        return probability
    }
}

private final class RisingTurn: TurnCompletionProvider, @unchecked Sendable {
    let answers: [Float]
    private(set) var calls = 0
    init(_ answers: [Float]) { self.answers = answers }
    func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float {
        defer { calls += 1 }
        return answers[min(calls, answers.count - 1)]
    }
}

extension TurnThresholds {
    func with(levelGateDb: Float?) -> TurnThresholds {
        var t = self
        t.levelGateDb = levelGateDb
        return t
    }
}

@Suite struct TurnDetectorTests {
    private let frame = [Float](repeating: 0, count: 512)

    /// Stage 2 on smart-turn alone (no agreement): the machinery under the shipped rules.
    static let smartTurnOnly = TurnThresholds(
        onsetMs: 250, holdMs: 300, smartTurnThreshold: 0.99,
        rechecks: [.init(afterMs: 600, threshold: 0.98), .init(afterMs: 800, threshold: 0.98)], maxSilenceMs: 1500)

    /// Agreement (A-M3-T09b): a finished sentence + smart-turn, a finished-sentence check at 900 ms, caps 1.5 / 2 s.
    static let agreement = TurnThresholds(
        onsetMs: 250, holdMs: 300, smartTurnThreshold: 0.99,
        rechecks: [.init(afterMs: 600, threshold: 0.99), .init(afterMs: 800, threshold: 0.99)], maxSilenceMs: 2000,
        requireSentenceEnd: true, sentenceEnd: .init(afterMs: 900, threshold: 0.5), sentenceCapMs: 1200)

    /// The shipped rules (M9.T05): agreement + the 1.5 s end of an unfinished sentence that smart-turn calls complete.
    static let shipped: TurnThresholds = {
        var t = agreement
        t.openEnd = .init(afterMs: 1500, threshold: 0.8)
        return t
    }()

    /// The `sentenceStable` machinery (off in the shipped file: it splits read-speech sentence pauses, A-M9-T05-V2).
    static let withStable: TurnThresholds = {
        var t = shipped
        t.sentenceStable = .init(probesMs: [200, 300], threshold: 0.92)
        return t
    }()

    private func detector(_ probabilities: [Float], complete: Float = 0,
                          thresholds: TurnThresholds = Self.smartTurnOnly) -> TurnDetector {
        TurnDetector(vad: SequenceVAD(probabilities), smartTurn: StubTurn(complete), thresholds: thresholds)
    }

    private func feed(_ detector: TurnDetector, count: Int) -> [TurnDetectorEvent] {
        (0..<count).flatMap { _ in detector.process(samples: frame) }
    }

    @Test func testMaxSilenceAlwaysEnds() {
        let d = detector([Float](repeating: 0.9, count: 10) + [Float](repeating: 0, count: 60))
        _ = feed(d, count: 10)
        var events: [TurnDetectorEvent] = []
        for _ in 0..<60 {
            events += d.process(samples: frame)
            if events.contains(where: { if case .turnEnded = $0 { true } else { false } }) { break }
        }
        guard case .turnEnded(let reason, _, _, _, _, _)? = events.last else {
            Issue.record("no turn end: \(events)")
            return
        }
        #expect(reason == .silenceCap)
        #expect(events.filter { if case .paused = $0 { false } else { true } }.count == 2)
    }

    @Test func incompleteOneSecondPauseDoesNotSplit() {
        let d = detector(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 31)
            + Array(repeating: 0.9, count: 10))
        _ = feed(d, count: 10)
        let pause = feed(d, count: 31)
        #expect(!pause.contains { if case .turnEnded = $0 { true } else { false } })
        #expect(d.isHoldingTurn)
        let resumed = feed(d, count: 10)
        #expect(!resumed.contains { if case .turnEnded = $0 { true } else { false } })
        #expect(!d.isHoldingTurn)
    }

    @Test func completePauseEndsAtHold() {
        let d = detector(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 10), complete: 0.99)
        _ = feed(d, count: 10)
        let events = feed(d, count: 10)
        guard case .turnEnded(let reason, _, _, _, _, _)? = events.last else {
            Issue.record("no smart-turn end: \(events)")
            return
        }
        #expect(reason == .smartTurn)
    }

    @Test func eouEndsAHeldTurnButNeverASpeakerStillTalking() {
        let d = detector(Array(repeating: 0.9, count: 20) + Array(repeating: 0, count: 20))
        _ = feed(d, count: 15)
        #expect(d.endOfUtterance() == nil, "speech still going: an early EOU token does not cut the speaker")
        _ = feed(d, count: 5 + 12)  // ≥ holdMs (300 ms) of silence: stage 1 holds
        #expect(d.isHoldingTurn)
        guard case .turnEnded(let reason, _, _, _, _, _)? = d.endOfUtterance() else {
            Issue.record("EOU did not end the held turn")
            return
        }
        #expect(reason == .eou)
        #expect(d.endOfUtterance() == nil)
    }

    /// Stage 2 is asked again while the silence grows: an "incomplete" at the hold, "complete" by the recheck.
    @Test func recheckEndsTurnBeforeTheCap() {
        let turn = RisingTurn([0.2, 0.99])
        let t = TurnThresholds(onsetMs: 250, holdMs: 300, smartTurnThreshold: 0.99,
                               rechecks: [.init(afterMs: 600, threshold: 0.98)], maxSilenceMs: 1500)
        let d = TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 60)),
                             smartTurn: turn, thresholds: t)
        _ = feed(d, count: 10)
        var events: [TurnDetectorEvent] = []
        var frames = 0
        while frames < 60, !events.contains(where: { if case .turnEnded = $0 { true } else { false } }) {
            events += d.process(samples: frame)
            frames += 1
        }
        guard case .turnEnded(let reason, _, _, _, _, _)? = events.last else {
            Issue.record("no end: \(events)")
            return
        }
        #expect(reason == .smartTurn)
        #expect(turn.calls == 2)
        #expect(frames * 32 >= 600 && frames * 32 < 700, "ended at the 600 ms recheck, not the 1.5 s cap: \(frames * 32) ms")
    }

    /// Feeds silence frames until a turn end (or `max`); returns its reason and the silence in ms when it ended.
    /// `text` is handed to the detector at its `.paused` event, as the session does with the provisional transcript.
    private func endAfterPause(_ d: TurnDetector, text: String?, max: Int = 80) -> (VoiceTurnEndReason, Int)? {
        for n in 1...max {
            for e in d.process(samples: frame) {
                if case .paused(let voiced) = e, let text { d.setTranscript(text, voicedSample: voiced) }
                if case .turnEnded(let reason, _, _, _, _, _) = e { return (reason, n * 32) }
            }
        }
        return nil
    }

    private func agreeing(_ complete: Float) -> TurnDetector {
        detector(Array(repeating: 0.9, count: 10), complete: complete, thresholds: Self.agreement)
    }

    @Test func agreementEndsAFinishedSentenceAtTheHold() {
        let d = agreeing(0.99)
        _ = feed(d, count: 10)
        let end = endAfterPause(d, text: "What time is it?")
        #expect(end?.0 == .smartTurn)
        #expect((end?.1 ?? 0) >= 300 && (end?.1 ?? 0) < 400, "\(String(describing: end))")
    }

    @Test func agreementKeepsAnUnfinishedSentenceOpenUntilTheOpenCap() {
        let d = agreeing(0.99)  // smart-turn says "complete", the words do not
        _ = feed(d, count: 10)
        let end = endAfterPause(d, text: "I went to the")
        #expect(end?.0 == .silenceCap)
        #expect((end?.1 ?? 0) >= 2000, "\(String(describing: end))")
    }

    @Test func agreementFinishedSentenceCheckAndCap() {
        let mid = agreeing(0.6)  // below the hold's 0.99, above the 900 ms check's 0.5
        _ = feed(mid, count: 10)
        let a = endAfterPause(mid, text: "The woman seemed thoughtful.")
        #expect(a?.0 == .smartTurn && (a?.1 ?? 0) >= 900 && (a?.1 ?? 0) < 1000, "\(String(describing: a))")
        let low = agreeing(0.1)  // smart-turn never agrees: the finished-sentence cap (1.2 s), not the open one
        _ = feed(low, count: 10)
        let b = endAfterPause(low, text: "The woman seemed thoughtful.")
        #expect(b?.0 == .silenceCap && (b?.1 ?? 0) >= 1200 && (b?.1 ?? 0) < 1300, "\(String(describing: b))")
    }

    private func shippedRules(_ turn: any TurnCompletionProvider) -> TurnDetector {
        TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10)), smartTurn: turn, thresholds: Self.withStable)
    }

    /// M9.T05: smart-turn sure from 200 ms on (0.95, under the hold's 0.99) + a finished sentence → the turn ends at the
    /// 300 ms probe, not at the 900 ms check.
    @Test func stableFinishedSentenceEndsAtTheSecondProbe() {
        let d = shippedRules(StubTurn(0.95))
        _ = feed(d, count: 10)
        let end = endAfterPause(d, text: "The woman seemed thoughtful.")
        #expect(end?.0 == .smartTurn)
        #expect((end?.1 ?? 0) >= 300 && (end?.1 ?? 0) < 400, "\(String(describing: end))")
    }

    /// A pause where smart-turn climbs (0.6 at 200 ms, then sure): not an early end; the 900 ms check ends it.
    @Test func stableNeedsEveryProbe() {
        let turn = RisingTurn([0.6, 0.97])
        let d = shippedRules(turn)
        _ = feed(d, count: 10)
        let end = endAfterPause(d, text: "No one saw him do this, for all were looking at the powder of life.")
        #expect(end?.0 == .smartTurn)
        #expect((end?.1 ?? 0) >= 900 && (end?.1 ?? 0) < 1000, "\(String(describing: end))")
    }

    /// Below the threshold at both probes: no early end either.
    @Test func stableBelowThresholdKeepsListening() {
        let d = shippedRules(StubTurn(0.9))
        _ = feed(d, count: 10)
        let end = endAfterPause(d, text: "The woman seemed thoughtful.")
        #expect((end?.1 ?? 0) >= 900, "\(String(describing: end))")
    }

    /// The early end needs the words: an unfinished sentence never ends at the probes, whatever smart-turn says; with
    /// smart-turn sure it ends at the 1.5 s open-sentence check, without it at the 2 s cap.
    @Test func openSentenceEndsAtOpenEndOnlyWithSmartTurn() {
        let sure = shippedRules(StubTurn(0.99))
        _ = feed(sure, count: 10)
        let a = endAfterPause(sure, text: "Mother cried she, I see you here. Look look")
        #expect(a?.0 == .smartTurn && (a?.1 ?? 0) >= 1500 && (a?.1 ?? 0) < 1600, "\(String(describing: a))")
        let unsure = shippedRules(StubTurn(0.01))
        _ = feed(unsure, count: 10)
        let b = endAfterPause(unsure, text: "But first I will tell you that for many years I have longed for a servant,")
        #expect(b?.0 == .silenceCap && (b?.1 ?? 0) >= 2000, "\(String(describing: b))")
    }

    /// A transcript that arrives after the probes still ends the turn at once when both agreed.
    @Test func stableEndsWhenALateTranscriptArrives() {
        let d = TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 80)),
                             smartTurn: StubTurn(0.95), thresholds: Self.withStable)
        var voiced: Int?
        var ended = false
        for _ in 0..<(10 + 11) {  // 352 ms of silence: both probes asked, no transcript yet
            for e in d.process(samples: frame) {
                if case .paused(let v) = e { voiced = v }
                if case .turnEnded = e { ended = true }
            }
        }
        #expect(!ended && voiced != nil)
        guard case .turnEnded(let reason, _, _, _, _, _)? = d.setTranscript("Is it raining?", voicedSample: voiced ?? 0) else {
            Issue.record("no end on the late transcript"); return
        }
        #expect(reason == .smartTurn)
    }

    @Test func agreementWithoutATranscriptWaitsThenCaps() {
        let d = agreeing(0.99)
        _ = feed(d, count: 10)
        // No transcript arrives (the recogniser is slow): no check counts until it does.
        let end = endAfterPause(d, text: nil)
        #expect(end?.0 == .silenceCap && (end?.1 ?? 0) >= 2000)
        let none = agreeing(0.99)
        none.expectsTranscript = false  // no recogniser at all: smart-turn alone (review finding 4/5)
        _ = feed(none, count: 10)
        #expect(endAfterPause(none, text: nil)?.0 == .smartTurn)
    }

    @Test func aRecogniserWithoutPauseTranscriptsFallsBackToSmartTurn() {
        let d = TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 80)),
                             smartTurn: StubTurn(0.99), thresholds: Self.agreement)
        var events = feed(d, count: 16)
        guard let voiced = events.compactMap({ e -> Int? in if case .paused(let v) = e { v } else { nil } }).first else {
            Issue.record("no pause"); return
        }
        if let end = d.setTranscript(nil, voicedSample: voiced) { events.append(end) }  // WhisperKit: nothing at a pause
        events += feed(d, count: 40)
        let ends = events.compactMap { e -> VoiceTurnEndReason? in if case .turnEnded(let r, _, _, _, _, _) = e { r } else { nil } }
        #expect(ends == [.smartTurn])
    }

    @Test func anOlderPauseTranscriptNeverReplacesANewerOne() {
        let d = TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 80)),
                             smartTurn: StubTurn(0.99), thresholds: Self.agreement)
        let events = feed(d, count: 16)
        guard let voiced = events.compactMap({ e -> Int? in if case .paused(let v) = e { v } else { nil } }).first else {
            Issue.record("no pause"); return
        }
        let end = d.setTranscript("Is it raining?", voicedSample: voiced)
        #expect(d.setTranscript("Is it", voicedSample: voiced - 512) == nil)
        #expect(end != nil || d.isInTurn)
    }

    @Test func pausedIsReportedOncePerSilenceAndTranscriptsGoStaleOnSpeech() {
        let d = TurnDetector(vad: SequenceVAD(Array(repeating: 0.9, count: 10) + Array(repeating: 0, count: 6)
                                              + Array(repeating: 0.9, count: 4)),
                             smartTurn: StubTurn(0.99), thresholds: Self.agreement)
        let events = feed(d, count: 16)
        let paused = events.compactMap { e -> Int? in if case .paused(let v) = e { v } else { nil } }
        #expect(paused.count == 1)
        d.setTranscript("Is it raining?", voicedSample: paused[0])
        _ = feed(d, count: 4)  // the speaker goes on: the old transcript no longer describes the turn
        let end = endAfterPause(d, text: nil)
        #expect(end?.0 == .silenceCap && (end?.1 ?? 0) >= 2000, "a stale finished sentence never ends the turn")
    }

    @Test func endsSentence() {
        #expect(TurnDetector.endsSentence("Hello there."))
        #expect(TurnDetector.endsSentence("Is it?  "))
        #expect(TurnDetector.endsSentence("今日は。"))
        #expect(!TurnDetector.endsSentence("I have longed for a servant,"))
        #expect(!TurnDetector.endsSentence(""))
    }

    @Test func pushToTalkReleaseEndsTheTurn() {
        let d = detector(Array(repeating: 0.9, count: 20))
        _ = feed(d, count: 12)
        guard case .turnEnded(let reason, _, _, _, _, _)? = d.endTurnNow() else {
            Issue.record("PTT did not end the turn")
            return
        }
        #expect(reason == .ptt)
    }

    @Test func shortOnsetDoesNotOpenTurn() {
        let d = detector(Array(repeating: 0.9, count: 7) + [0])
        let events = feed(d, count: 8)
        #expect(events.isEmpty)
        #expect(d.endOfUtterance() == nil)
    }

    @Test func thresholdsComeFromDataFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/Engines/Sources/AntiChatEngines/Voice/turn-thresholds.json")
        let t = try TurnThresholds.load(from: url)
        #expect(t.onsetMs == 250 && t.holdMs == 300 && t.sentenceCapMs == 1200 && t.maxSilenceMs == 2000)
        #expect(t.smartTurnThreshold == 0.99 && t.rechecks.map(\.afterMs) == [600, 800])
        #expect(t.requireSentenceEnd == true && t.sentenceEnd == .init(afterMs: 900, threshold: 0.5))
        #expect(t.sentenceStable == nil && t.openEnd == .init(afterMs: 1500, threshold: 0.8))
        #expect(t == .standard && t == Self.shipped.with(levelGateDb: 10))
    }
}

private final class BurstCapture: AudioCaptureSource, @unchecked Sendable {
    var callback: (@Sendable ([Float]) -> Void)?
    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws { callback = onSamples }
    func send(_ count: Int) { callback?([Float](repeating: 0, count: count)) }
    func stop() { callback = nil }
}

@Suite struct VoiceAudioEngineInjectionTests {
    @Test func injectedCaptureBypassesVPIOAndEmits32msFrames() {
        let source = BurstCapture()
        let audio = VoiceAudioEngine(injected: source)
        let frames = Mutex<[Int]>([])
        try! audio.start { samples in frames.withLock { $0.append(samples.count) } }
        source.send(320)
        source.send(704)
        #expect(frames.withLock { $0 } == [512, 512])
        #expect(!audio.isEchoCancellationActive)
        audio.stop()
        source.send(512)
        #expect(frames.withLock { $0 } == [512, 512])
    }
}
