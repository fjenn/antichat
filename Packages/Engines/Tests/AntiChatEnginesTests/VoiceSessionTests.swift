// M3.T10 (R-052 AC3, R-282 AC2): a whole VoiceSession without models — pushed input frames, an amplitude "VAD", a
// fake recogniser and a silent-clocked synthesiser. Turn → final transcript → spoken reply → barge-in → the reply
// stops, the spoken span is reported, and the new utterance is answered. Real models: BargeInFixtureTests.
//   make test-unit FILTER=VoiceSessionTests
import AntiChatEngineProtocol
import Foundation
import SpeechSwiftVendored
import Synchronization
import Testing
@testable import AntiChatEngines

/// Real-time-free capture: the test pushes frames.
final class PushCapture: AudioCaptureSource, @unchecked Sendable {
    private let cb = Mutex<(@Sendable ([Float]) -> Void)?>(nil)
    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws { cb.withLock { $0 = onSamples } }
    func stop() { cb.withLock { $0 = nil } }
    func push(_ samples: [Float]) {
        let f = cb.withLock { $0 }
        var i = 0
        while i < samples.count {
            f?(Array(samples[i..<min(i + 512, samples.count)]))
            i += 512
        }
    }
    static func loud(_ s: Double) -> [Float] { (0..<Int(s * 16_000)).map { 0.2 * sin(Float($0) * 0.07) } }
    static func quiet(_ s: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(s * 16_000)) }
}

/// P(speech) = 0.9 for a frame with any sample over 0.05, else 0.
final class AmplitudeVAD: StreamingVADProvider, @unchecked Sendable {
    let inputSampleRate = 16_000
    let chunkSize = 512
    func processChunk(_ samples: [Float]) -> Float { samples.contains { abs($0) > 0.05 } ? 0.9 : 0 }
    func resetState() {}
}

final class AlwaysComplete: TurnCompletionProvider, @unchecked Sendable {
    func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float { 1 }
}

/// 0.6 s of near-silence per chunk, synthesised at once.
struct SilentSynth: SpeechSynthesizing {
    let name = "silent"
    func synthesize(_ text: String) async throws -> SynthesizedAudio {
        SynthesizedAudio(samples: [Float](repeating: 0.001, count: 14_400), sampleRate: 24_000)
    }
}

@Suite(.serialized) struct VoiceSessionTests {
    static func session(sink: VoiceSink, capture: PushCapture, texts: [String]) -> VoiceSession {
        let queue = Mutex(texts)
        let parts = VoiceSessionParts(
            capture: capture, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: {
                let t = queue.withLock { $0.isEmpty ? "Again." : $0.removeFirst() }
                return (FakeBackend(finalText: t), [])
            },
            synthesiser: { KokoroBackend(tts: SilentSynth(), playback: $0) },
            sink: ClockedSilentSink())
        return VoiceSession(start: VoiceSessionStart(chatID: UUID(), voiceID: "af_heart"), parts: parts, emit: sink.emit)
    }

    static func wait(_ what: String, timeout: Double = 20, _ cond: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(timeout)
        while !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cond(), "timed out waiting for \(what)")
    }

    @Test func turnReplyBargeInAndNextTurn() async throws {
        let sink = VoiceSink()
        let mic = PushCapture()
        let s = Self.session(sink: sink, capture: mic, texts: ["What is the weather?", "Stop, tell me a joke."])
        try await s.begin()
        #expect(sink.voice.first == .voiceState(.listening))

        // The user speaks 0.6 s, then is quiet: smart-turn says complete at the 300 ms hold.
        mic.push(PushCapture.quiet(0.3) + PushCapture.loud(0.6) + PushCapture.quiet(0.5))
        await Self.wait("final") { sink.finals.count == 1 }
        #expect(sink.finals.first?.text == "What is the weather?")
        #expect(sink.voice.contains(.turnEnded(.smartTurn)))
        #expect(await s.state == .thinking)

        // The reply streams in; its first chunk starts playing.
        let turn = UUID()
        let reply = "It is sunny and warm today, with a light breeze. Tonight it gets colder. Tomorrow it rains."
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            await s.control(.speak(text: String(word) + " ", turnID: turn))
        }
        await s.control(.speakEnd(turnID: turn))
        await Self.wait("speaking") { sink.voice.contains(.ttsStarted(chunkIndex: 0)) }
        #expect(await s.state == .speaking)
        try await Task.sleep(for: .milliseconds(700))  // the first chunk (0.6 s) has played, the second is playing

        // Barge-in: 0.4 s of speech → pause at the first frame, stop at 250 ms; the span is reported.
        mic.push(PushCapture.loud(0.4))
        await Self.wait("barge-in") { sink.voice.contains { if case .ttsStopped(_, .bargeIn) = $0 { true } else { false } } }
        let span = sink.voice.compactMap { e -> Int? in if case .spokenSpan(let id, let o) = e, id == turn { o } else { nil } }
        #expect(span.count == 1)
        let heard = span.first ?? 0
        #expect(heard > 0 && heard < reply.utf16.count, "stored = spoken prefix, not the whole reply: \(heard)")
        let stored = String(reply.utf16.prefix(heard))!
        #expect(stored.hasPrefix("It is sunny and warm today,"), "the first chunk was heard: \(stored)")
        #expect(await s.state == .transcribing)

        // The interrupting utterance is answered (R-052 AC3).
        mic.push(PushCapture.loud(0.3) + PushCapture.quiet(0.6))
        await Self.wait("second final") { sink.finals.count == 2 }
        #expect(sink.finals.last?.text == "Stop, tell me a joke.")
        await s.end()
        #expect(sink.voice.last == .voiceState(.idle))
    }

    @Test func naturalEndReportsTheWholeReply() async throws {
        let sink = VoiceSink()
        let mic = PushCapture()
        let s = Self.session(sink: sink, capture: mic, texts: ["Hi."])
        try await s.begin()
        mic.push(PushCapture.loud(0.5) + PushCapture.quiet(0.5))
        await Self.wait("final") { sink.finals.count == 1 }
        let turn = UUID()
        await s.control(.speak(text: "Hello there, nice to meet you.", turnID: turn))
        await s.control(.speakEnd(turnID: turn))
        await Self.wait("finished") { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
        #expect(sink.voice.contains(.spokenSpan(turnID: turn, charOffset: 30)))
        #expect(await s.state == .listening)
        await s.end()
    }

    @Test func coughDuringReplyDoesNotInterrupt() async throws {
        let sink = VoiceSink()
        let mic = PushCapture()
        let s = Self.session(sink: sink, capture: mic, texts: ["Hi."])
        try await s.begin()
        mic.push(PushCapture.loud(0.5) + PushCapture.quiet(0.5))
        await Self.wait("final") { sink.finals.count == 1 }
        let turn = UUID()
        await s.control(.speak(text: "One two three four, five six. Seven eight nine.", turnID: turn))
        await s.control(.speakEnd(turnID: turn))
        await Self.wait("speaking") { sink.voice.contains(.ttsStarted(chunkIndex: 0)) }
        try await Task.sleep(for: .milliseconds(200))
        mic.push(PushCapture.loud(0.1) + PushCapture.quiet(0.3))  // a 100 ms cough
        await Self.wait("finished", timeout: 8) { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
        #expect(!sink.voice.contains { if case .ttsStopped(_, .bargeIn) = $0 { true } else { false } })
        await s.end()
    }
}

/// NFR-V1: the voice session's recogniser is the language-routed one; it must hand Parakeet's pause transcript on.
@Suite struct RoutedProvisionalTests {
    @Test func routedBackendForwardsTheProvisionalTranscript() async throws {
        let routed = RoutedBackend(parakeet: FakeBackend(finalText: "Is it raining?"),
                                   whisper: { throw CocoaError(.featureUnsupported) }, setting: "en")
        _ = try await routed.start(locale: Locale(identifier: "en"))
        routed.append(samples: [Float](repeating: 0, count: 8_000))
        let p = try await routed.provisional()
        #expect(p?.text == "Is it raining?")
        await routed.cancel()
    }
}
