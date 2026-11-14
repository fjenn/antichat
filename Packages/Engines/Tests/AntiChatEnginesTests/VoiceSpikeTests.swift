// M0.T05 voice spike: pure logic (always) + the real voice models on a `say` fixture (when the dev model
// store has them; set ANTICHAT_VOICE_IT=1). No network: FluidAudio offline mode is on (D-11).
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct EndpointerTests {
    @Test func smartTurnCompleteEndsAfter200ms() {
        var ep = Endpointer()
        for k in 0..<20 { #expect(ep.feed(probability: 0.9, frameIndex: k) == .none) }
        #expect(ep.speechStartFrame == 0)
        // 6 silent frames = 192 ms < 200 ms; the 7th (224 ms) asks stage 2.
        for k in 20..<26 { #expect(ep.feed(probability: 0.05, frameIndex: k) == .none) }
        #expect(ep.feed(probability: 0.05, frameIndex: 26) == .askTurn)
        #expect(ep.turnAnswer(probability: 0.8) == .endTurn(reason: "smartTurn"))
        #expect(ep.lastVoicedFrame == 19)
    }

    @Test func incompleteTurnWaitsForMaxSilence() {
        var ep = Endpointer()
        for k in 0..<10 { _ = ep.feed(probability: 0.9, frameIndex: k) }
        var k = 10
        var ended: Endpointer.Action = .none
        while k < 100 {
            var a = ep.feed(probability: 0.0, frameIndex: k)
            if a == .askTurn { a = ep.turnAnswer(probability: 0.2) }
            if case .endTurn = a { ended = a; break }
            k += 1
        }
        #expect(ended == .endTurn(reason: "maxSilence"))
        // 1.2 s / 32 ms = 37.5 → the 38th silent frame.
        #expect(k - 10 + 1 == 38)
    }

    @Test func speechResumesResetsSilence() {
        var ep = Endpointer()
        for k in 0..<5 { _ = ep.feed(probability: 0.9, frameIndex: k) }
        for k in 5..<10 { _ = ep.feed(probability: 0.0, frameIndex: k) }
        _ = ep.feed(probability: 0.9, frameIndex: 10)
        for k in 11..<17 { #expect(ep.feed(probability: 0.0, frameIndex: k) == .none) }
        #expect(ep.lastVoicedFrame == 10)
    }

    @Test func singleBlipIsNotSpeech() {
        var ep = Endpointer()
        _ = ep.feed(probability: 0.9, frameIndex: 0)
        _ = ep.feed(probability: 0.0, frameIndex: 1)
        #expect(!ep.inSpeech)
    }

    @Test func waveformEndOfSpeech() {
        var x = [Float](repeating: 0, count: 16_000)
        for i in 3_000..<8_000 { x[i] = 0.1 * sin(Float(i) * 0.3) }
        let e = lastVoicedSample(x)
        #expect(e == 8_000)
    }
}

@Suite struct SentenceSplitterTests {
    @Test func splitsOnPunctuationFollowedBySpace() {
        var s = SentenceSplitter()
        #expect(s.push("Paris is the cap").isEmpty)
        #expect(s.push("ital.").isEmpty)
        #expect(s.push(" It is") == ["Paris is the capital."])
        #expect(s.flush() == "It is")
    }

    @Test func decimalsDoNotSplit() {
        var s = SentenceSplitter()
        #expect(s.push("It is 3.5 km away. Ok").count == 1)
    }

    @Test func twelveWordCap() {
        var s = SentenceSplitter()
        let out = s.push("one two three four five six seven eight nine ten eleven twelve thirteen")
        #expect(out == ["one two three four five six seven eight nine ten eleven twelve"])
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"))
struct VoiceModelsIntegrationTests {
    static let models = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    static let fixture: String = ProcessInfo.processInfo.environment["ANTICHAT_VOICE_FIXTURE"] ?? "build/t05-scratch/say-capital.aiff"

    @Test func vadTurnSttTts() async throws {
        VoiceEnvironment.lockDown()
        let speech = try SpikeVoiceSession.loadPCM16k(Self.fixture)
        let x = speech + [Float](repeating: 0, count: 32_000)
        let vad = try SileroFrameVAD(directory: Self.models.appendingPathComponent("vad-files"))
        var ep = Endpointer()
        var probs: [Float] = []
        let n = x.count / 512
        var reason: String?
        let turn = try SmartTurnLoader.load(turnDirectory: Self.models.appendingPathComponent("turn"))
        var turnProb: Float = -1
        for k in 0..<n {
            let p = try vad.probability(x[(k * 512)..<((k + 1) * 512)])
            probs.append(p)
            var a = ep.feed(probability: p, frameIndex: k)
            if a == .askTurn, let s = ep.speechStartFrame {
                turnProb = try turn.turnCompleteProbability(audio: Array(x[(s * 512)..<((k + 1) * 512)]), sampleRate: 16_000)
                a = ep.turnAnswer(probability: turnProb)
            }
            if case .endTurn(let r) = a { reason = r; break }
        }
        print("vad max \(probs.max() ?? -1) speechStart \(ep.speechStartFrame ?? -1) lastVoiced \(ep.lastVoicedFrame ?? -1) end \(reason ?? "-") smartTurn \(turnProb)")
        #expect(ep.speechStartFrame != nil)
        #expect(reason != nil)
        let stt = try await ParakeetSTT.load(directory: Self.models.appendingPathComponent("stt"))
        let text = try await stt.transcribe(speech)
        print("transcript: \(text)")
        #expect(text.lowercased().contains("france"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-fluid-tts-test")
        let k = try await KokoroTTS.load(ttsDirectory: Self.models.appendingPathComponent("tts"), linkRoot: tmp)
        let t0 = Date()
        let a = try await k.synthesize("Paris is the capital of France.")
        print("kokoro \(a.samples.count) samples @ \(a.sampleRate) in \(Date().timeIntervalSince(t0)) s")
        #expect(a.samples.count > a.sampleRate / 2)
        let sys = try await SystemTTS().synthesize("Paris is the capital of France.")
        print("system \(sys.samples.count) samples @ \(sys.sampleRate)")
        #expect(sys.samples.count > sys.sampleRate / 2)
    }
}
