// A-M3-T09c (NFR-V1): the speculative reply's first chunk is synthesised ahead of time and reused only when the
// adopted reply's first chunk is the same text; a different reply is synthesised fresh and nothing of the
// speculation is played.
//   make test-unit FILTER=PresynthesisTests
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct PresynthesisTests {
    @Test func theSameChunkIsReusedOnceAndOtherTextIsSynthesisedFresh() async throws {
        let inner = FakeSynth()
        let synth = PresynthesizingSynth(inner)
        synth.presynthesize("Hello there.", voice: nil, speed: 1)
        _ = try await synth.synthesize("Hello there.", voice: nil, speed: 1)
        #expect(inner.texts.withLock { $0 } == ["Hello there."], "synthesised once, ahead of time")
        #expect(synth.hits.withLock { $0 } == 1)
        _ = try await synth.synthesize("Hello there.", voice: nil, speed: 1)
        #expect(inner.texts.withLock { $0 }.count == 2, "used at most once")
        synth.presynthesize("Hi.", voice: nil, speed: 1)
        _ = try await synth.synthesize("Hi.", voice: "af_bella", speed: 1)
        #expect(synth.hits.withLock { $0 } == 1, "another voice never matches")
    }

    static func session(_ sink: VoiceSink, _ mic: PushCapture, synth: PresynthesizingSynth) -> VoiceSession {
        let parts = VoiceSessionParts(
            capture: mic, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: { (FakeBackend(finalText: "What is the weather?"), []) },
            synthesiser: { KokoroBackend(tts: synth, playback: $0) },
            sink: ClockedSilentSink(),
            presynthesize: { text, voice, rate in
                synth.presynthesize(text, voice: voice.isEmpty ? nil : voice, speed: min(1.5, max(0.75, rate)))
            })
        return VoiceSession(start: VoiceSessionStart(chatID: UUID(), voiceID: "af_heart"), parts: parts, emit: sink.emit)
    }

    static func speak(_ s: VoiceSession, _ reply: String) async {
        let turn = UUID()
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            await s.control(.speak(text: String(word) + " ", turnID: turn))
        }
        await s.control(.speakEnd(turnID: turn))
    }

    @Test func anAdoptedReplyPlaysThePresynthesisedFirstChunk() async throws {
        let inner = FakeSynth()
        let synth = PresynthesizingSynth(inner)
        let sink = VoiceSink()
        let mic = PushCapture()
        let s = Self.session(sink, mic, synth: synth)
        try await s.begin()
        mic.push(PushCapture.loud(0.6) + PushCapture.quiet(0.5))
        await VoiceSessionTests.wait("final") { sink.finals.count == 1 }
        let reply = "It is sunny today. Tonight it gets colder."
        await s.control(.speculate(text: "It is sunny today. Tonight"))
        await VoiceSessionTests.wait("presynthesis") { inner.texts.withLock { $0.count } == 1 }
        await Self.speak(s, reply)
        await VoiceSessionTests.wait("finished") { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
        #expect(synth.hits.withLock { $0 } == 1, "the first chunk came from the presynthesis")
        #expect(inner.texts.withLock { $0 } == ["It is sunny today.", "Tonight it gets colder."])
        await s.end()
    }

    @Test func aDiscardedSpeculationIsNeverPlayed() async throws {
        let inner = FakeSynth()
        let synth = PresynthesizingSynth(inner)
        let sink = VoiceSink()
        let mic = PushCapture()
        let s = Self.session(sink, mic, synth: synth)
        try await s.begin()
        mic.push(PushCapture.loud(0.6) + PushCapture.quiet(0.5))
        await VoiceSessionTests.wait("final") { sink.finals.count == 1 }
        await s.control(.speculate(text: "Paris is the capital of France. It"))
        await VoiceSessionTests.wait("presynthesis") { inner.texts.withLock { $0.count } == 1 }
        await Self.speak(s, "It is sunny today.")
        await VoiceSessionTests.wait("finished") { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
        #expect(synth.hits.withLock { $0 } == 0)
        let spoken = sink.voice.compactMap { e -> String? in if case .speakingText(let t) = e { t } else { nil } }
        #expect(spoken == ["It is sunny today."], "only the reply's own chunks are spoken")
        await s.end()
    }
}
