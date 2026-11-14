// M3.T10 step 7: every VoiceSession transition (pure machine), the barge-in detector, the reply chunking and the
// spoken-span truncation (R-282 AC1–AC3).
//   make test-unit FILTER='VoiceSessionStateTests|BargeInDetectorTests|SpokenSpanTests|VoiceReplyTextTests'
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct VoiceSessionStateTests {
    @Test func happyPathTurn() {
        var m = VoiceSessionMachine()
        #expect(m.next(.start) == [.startCapture, .emitState(.listening)])
        #expect(m.next(.speechStarted) == [.emitState(.transcribing)])
        #expect(m.next(.turnEnded(.smartTurn)) == [.emitTurnEnded(.smartTurn)])
        #expect(m.next(.finalReady(text: "what time is it")) == [.emitFinal("what time is it"), .emitState(.thinking)])
        let id = UUID()
        #expect(m.next(.replyStarted(turnID: id)) == [])
        #expect(m.turnID == id)
        #expect(m.next(.replyAudio) == [.emitState(.speaking)])
        #expect(m.next(.replyDone) == [.emitState(.listening)])
        #expect(m.state == .listening && m.turnID == nil)
    }

    @Test func emptyFinalGoesBackToListening() {
        var m = VoiceSessionMachine()
        _ = m.next(.start); _ = m.next(.speechStarted); _ = m.next(.turnEnded(.silenceCap))
        #expect(m.next(.finalReady(text: "  ")) == [.emitState(.listening)])
        #expect(m.state == .listening)
    }

    private func speaking() -> (VoiceSessionMachine, UUID) {
        var m = VoiceSessionMachine()
        let id = UUID()
        for e: VoiceSessionMachine.Event in [.start, .speechStarted, .turnEnded(.smartTurn), .finalReady(text: "hi"),
                                             .replyStarted(turnID: id), .replyAudio] { _ = m.next(e) }
        return (m, id)
    }

    @Test func bargeInWhileSpeakingPausesThenStopsAndCancels() {
        var (m, id) = speaking()
        #expect(m.next(.bargeCandidate) == [.pauseOutput])
        #expect(m.next(.bargeCandidate) == [], "already paused")
        #expect(m.next(.bargeConfirmed) == [.stopSpeech(turnID: id, reason: .bargeIn), .cancelGeneration(turnID: id),
                                            .emitState(.transcribing)])
        #expect(m.state == .transcribing, "the new utterance is already being heard (its onset audio kept)")
    }

    @Test func pushToTalkBargeInWithoutSpaceReturnsToListening() {
        var (m, _) = speaking()
        _ = m.next(.bargeConfirmed)
        #expect(m.next(.abandonTurn) == [.emitState(.listening)])
        #expect(m.state == .listening)
    }

    @Test func coughResumesTheReply() {
        var (m, _) = speaking()
        _ = m.next(.bargeCandidate)
        #expect(m.next(.bargeFalseAlarm) == [.resumeOutput])
        #expect(m.state == .speaking && !m.outputPaused)
    }

    @Test func bargeInDuringThinkingCancelsGenerationWithoutTTS() {
        var m = VoiceSessionMachine()
        let id = UUID()
        for e: VoiceSessionMachine.Event in [.start, .speechStarted, .turnEnded(.smartTurn), .finalReady(text: "hi"),
                                             .replyStarted(turnID: id)] { _ = m.next(e) }
        #expect(m.state == .thinking)
        #expect(m.next(.bargeCandidate) == [], "nothing to pause")
        #expect(m.next(.bargeConfirmed) == [.cancelGeneration(turnID: id), .emitState(.transcribing)])
    }

    @Test func halfDuplexAndMutedMicIgnoreBargeIn() {
        var (m, _) = speaking()
        _ = m.next(.setHalfDuplex(true))
        #expect(m.next(.bargeCandidate) == [])
        #expect(m.next(.bargeConfirmed) == [])
        _ = m.next(.setHalfDuplex(false))
        _ = m.next(.muteMic(true))
        #expect(m.next(.bargeConfirmed) == [])
        #expect(m.state == .speaking)
    }

    @Test func mutedMicStartsNoTurn() {
        var m = VoiceSessionMachine()
        _ = m.next(.start)
        _ = m.next(.muteMic(true))
        #expect(m.next(.speechStarted) == [])
        #expect(m.state == .listening)
    }

    @Test func speakerMuteKeepsTheClock() {
        var (m, _) = speaking()
        #expect(m.next(.muteSpeaker(true)) == [.setOutputMuted(true)])
        #expect(m.state == .speaking)
    }

    @Test func typedMessageDuringListeningIsSpoken() {
        var m = VoiceSessionMachine()
        _ = m.next(.start)
        let id = UUID()
        #expect(m.next(.replyStarted(turnID: id)) == [.emitState(.thinking)])
        #expect(m.next(.replyAudio) == [.emitState(.speaking)])
    }

    @Test func endFromEveryState() {
        var (m, id) = speaking()
        #expect(m.next(.end) == [.stopSpeech(turnID: id, reason: .stopped), .stopCapture, .emitState(.idle)])
        #expect(m.state == .idle)
        #expect(m.next(.end) == [])
        var l = VoiceSessionMachine()
        _ = l.next(.start)
        #expect(l.next(.end) == [.stopCapture, .emitState(.idle)])
        #expect(l.next(.speechStarted) == [], "idle ignores input")
    }
}

@Suite struct BargeInDetectorTests {
    private func run(_ d: inout BargeInDetector, _ ps: [Float], from sample: Int = 0) -> [BargeInDetector.Decision] {
        var out: [BargeInDetector.Decision] = []
        for (i, p) in ps.enumerated() {
            let r = d.feed(probability: p, endSample: sample + (i + 1) * 512)
            if r != .none { out.append(r) }
            if case .confirmed = r { break }  // the session stops feeding the detector once a barge-in is confirmed
        }
        return out
    }

    @Test func onsetPausesAt1FrameAndConfirmsAt250ms() {
        var d = BargeInDetector()
        let r = run(&d, [0, 0, 0, 0, 0, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9])
        #expect(r == [.candidate(onsetSample: 5 * 512), .confirmed(onsetSample: 5 * 512)])
    }

    @Test func coughUnder250msIsAFalseAlarm() {
        var d = BargeInDetector()
        let r = run(&d, [0, 0, 0, 0, 0, 0.9, 0.9, 0.9, 0, 0, 0, 0, 0, 0])
        #expect(r == [.candidate(onsetSample: 5 * 512), .falseAlarm])
    }

    @Test func oneQuietFrameInsideAnOnsetDoesNotReset() {
        var d = BargeInDetector()
        let r = run(&d, [0, 0, 0, 0, 0, 0.9, 0.9, 0.9, 0.9, 0.1, 0.9, 0.9, 0.9, 0.9, 0.9])
        #expect(r.last == .confirmed(onsetSample: 5 * 512))
    }

    @Test func postPlaybackGuardIgnoresTheChunkAttack() {
        var d = BargeInDetector()
        _ = run(&d, [0, 0])
        d.chunkStarted()
        #expect(run(&d, [0.9, 0.9, 0.9, 0.9], from: 1024).isEmpty, "within 150 ms of a chunk start")
    }
}

@Suite struct VoiceReplyTextTests {
    @Test func firstChunkIsFirstClauseWithFourWords() {
        var r = VoiceReplyText()
        var out: [SpokenChunk] = []
        for token in ["Sure", ",", " here", " is", " the", " plan", ", step", " by", " step", ". Then", " more"] {
            out += r.feed(token)
        }
        out += r.finish()
        #expect(out.first?.text == "Sure, here is the plan,")
        #expect(out.map(\.index) == Array(0..<out.count))
    }

    @Test func markdownNeverSpokenAndRangesPointIntoTheSource() {
        let md = "## Title\n\nUse **bold** words.\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nDone now."
        var r = VoiceReplyText()
        var out: [SpokenChunk] = []
        for c in md { out += r.feed(String(c)) }
        out += r.finish()
        let spoken = out.map(\.text)
        #expect(spoken.contains("code omitted."))
        for s in spoken { #expect(!s.contains(where: { SpeakableText.forbidden.contains($0) }), "\(s)") }
        #expect(!spoken.joined().contains("let x"))
        let src = Array(md.utf16)
        let bold = out.first { $0.text.contains("bold") }!
        #expect(String(decoding: src[bold.source], as: UTF16.self) == "Use **bold** words.")
        #expect(r.text == md)
    }
}

@Suite struct SpokenSpanTests {
    /// Two chunks of 10 000 samples each over "One two three four. Five six seven eight."
    private func tracker() -> (SpokenSpanTracker, String) {
        let src = "One two three four. Five six seven eight."
        var r = VoiceReplyText()
        let chunks = r.feed(src) + r.finish()
        var t = SpokenSpanTracker()
        t.updateSource(src)
        for c in chunks { t.scheduled(c, samples: 10_000) }
        return (t, src)
    }

    private func words(_ s: Substring) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    @Test func stopAtZeroStoresNothing() {
        let (t, _) = tracker()
        #expect(t.spokenOffset(playedSamples: 0) == 0)
    }

    @Test func midChunkStoresTheWordInProgress() {
        let (t, src) = tracker()
        let o = t.spokenOffset(playedSamples: 4_000)  // ≈ 40 % into chunk 0: "One two" heard, "three" in progress
        let stored = src.utf16.prefix(o)
        #expect(abs(words(Substring(String(stored)!)) - 2) <= 1)
        #expect(String(stored)!.last?.isLetter == true, "rounded to a word end")
    }

    @Test func chunkBoundaryStoresTheFirstSentence() {
        let (t, src) = tracker()
        let o = t.spokenOffset(playedSamples: 10_000)
        #expect(String(src.utf16.prefix(o))! == "One two three four.")
    }

    /// Kokoro's predicted token durations give the word starts (BOS, phoneme characters, EOS; a space splits words).
    @Test func wordStartsFromPredictedDurations() {
        #expect(SynthesizedAudio.wordStarts(phonemes: "ab cd", durations: [2, 1, 1, 1, 1, 1, 2], frames: 9, samples: 900) == [200, 500])
        #expect(SynthesizedAudio.wordStarts(phonemes: "ab cd", durations: [2, 1, 1], frames: 4, samples: 400) == nil,
                "token / phoneme mismatch (out-of-vocab): fall back to the estimate")
    }

    @Test func realWordStartsDecideTheWordInProgress() {
        let src = "One two three four."
        var r = VoiceReplyText()
        let chunks = r.feed(src) + r.finish()
        var t = SpokenSpanTracker()
        t.updateSource(src)
        // A slow first word: "One" lasts until 6 000 of 10 000 samples.
        t.scheduled(chunks[0], samples: 10_000, wordStarts: [500, 6_000, 7_500, 9_000])
        #expect(String(src.utf16.prefix(t.spokenOffset(playedSamples: 5_000)))! == "One")
        #expect(String(src.utf16.prefix(t.spokenOffset(playedSamples: 6_100)))! == "One two")
    }

    @Test func lastWordStoresEverything() {
        let (t, src) = tracker()
        #expect(t.spokenOffset(playedSamples: 20_000) == src.utf16.count)
        #expect(t.spokenOffset(playedSamples: 19_900) == src.utf16.count, "the last word in progress counts")
    }
}
