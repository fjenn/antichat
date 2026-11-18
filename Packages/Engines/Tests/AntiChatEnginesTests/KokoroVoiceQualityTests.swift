// "Radio" voice regression (2026-11-18; `@realModels`, ANTICHAT_VOICE_IT=1, ANTICHAT_MODELS=<…/Models/installs>):
// with the shipped placement (tail on the GPU) every clause longer than ≈ 6.8 s came out as hiss at a third of the
// level — the AT-FA-05 tail rewrite is wrong on the GPU past 32 768 x_pre steps — while short clauses were clean, so a
// reply switched between a normal voice and a cracked "radio" one sentence by sentence. Each chunk of a realistic
// reply (voice-mode chunker) must sound like speech: first-difference/energy ratio (hiss) and level in the range of
// clean Kokoro speech, no NaN or clipping, the same samples on a repeat and when synthesised concurrently, and
// Parakeet hears the words. Plays nothing.
//   ANTICHAT_VOICE_IT=1 ANTICHAT_MODELS=… swift test --filter KokoroVoiceQualityTests
// ANTICHAT_KOKORO_QUALITY_DIR=<dir> also keeps each chunk as a WAV there.
import FluidAudio
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"))
struct KokoroVoiceQualityTests {
    static let reply = """
    Sure! Here are three quick tips for better sleep 😴:

    1. Keep your bedroom cool, around 18 °C (65 °F).
    2. Avoid screens for 30 minutes before bed.
    3. Try a consistent wake-up time, even on weekends — it really helps your body clock settle into a rhythm over \
    the next two or three weeks, according to most sleep researchers at places like https://www.sleepfoundation.org/tips.

    Got it? What time do you usually go to bed? Okay.
    """

    /// Energy of the first difference over the energy: ≈ 0.05–0.2 for clean Kokoro speech, ≈ 1 for the broken tail.
    static func hiss(_ x: [Float]) -> Double {
        var d = 0.0, e = 0.0
        for i in 1..<x.count {
            d += Double((x[i] - x[i - 1]) * (x[i] - x[i - 1]))
            e += Double(x[i] * x[i])
        }
        return d / max(e, 1e-12)
    }

    static func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, x.count))) }

    @Test(arguments: ["af_heart", "am_michael"]) func everyChunkOfAReplyIsCleanSpeech(voice: String) async throws {
        VoiceEnvironment.lockDown()
        let env = ProcessInfo.processInfo.environment
        let models = env["ANTICHAT_MODELS"].map(URL.init(fileURLWithPath:)) ?? ParakeetBackendTests.models
        let links = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-kokoro-quality-test", isDirectory: true)
        let tts = try await KokoroTTS.load(ttsDirectory: models.appendingPathComponent("tts"), linkRoot: links,
                                           placement: KokoroTTS.shippedPlacement)
        let stt = try await ParakeetModel.load(directory: models.appendingPathComponent("stt"))
        let keep = env["ANTICHAT_KOKORO_QUALITY_DIR"].map(URL.init(fileURLWithPath:))
        let scratch = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: scratch) } }

        let chunks = ClauseChunker.chunks(SpeakableText.from(markdown: Self.reply))
        #expect(chunks.contains { $0.count > 150 }, "the reply holds a long sentence (> 6.8 s of speech)")
        var errors = 0, words = 0
        var sequential: [[Float]] = []
        for (i, chunk) in chunks.enumerated() {
            let a = try await tts.synthesize(chunk, voice: voice, speed: 1)
            let again = try await tts.synthesize(chunk, voice: voice, speed: 1)
            let x = a.samples
            sequential.append(x)
            let h = Self.hiss(x), level = Self.rms(x), peak = x.map(abs).max() ?? 0
            print(String(format: "KokoroVoiceQuality %@ %d: %.1f s hiss %.3f rms %.4f peak %.3f — %@",
                         voice, i, Double(x.count) / Double(a.sampleRate), h, level, peak, chunk))
            #expect(x.allSatisfy(\.isFinite) && peak < 0.99, "\(voice) \(i): no NaN, no clipping")
            #expect(h < 0.5, "\(voice) \(i): hiss \(h) — \(chunk)")
            #expect(level > 0.025, "\(voice) \(i): level \(level) — \(chunk)")
            #expect(again.samples == x, "\(voice) \(i): deterministic")
            let url = scratch.appendingPathComponent("\(voice)-\(i).wav")
            try writeWAV(x, sampleRate: a.sampleRate, to: url)
            let backend = ParakeetBackend(model: stt)
            _ = try await backend.start(locale: Locale(identifier: "en"))
            backend.append(samples: try VoiceAudioConverter.readFile(url))
            let heard = try await backend.finish().text
            print("KokoroVoiceQuality \(voice) \(i) heard: \(heard)")
            // Numbers and units are spoken as words ("18 °C" → "eighteen degrees Celsius"): judged on letter-only chunks.
            if chunk.rangeOfCharacter(from: .decimalDigits) == nil {
                errors += WER.errors(WER.words(chunk), WER.words(heard))
                words += WER.words(chunk).count
            }
        }
        #expect(Double(errors) / Double(max(1, words)) <= 0.1, "\(voice): WER \(errors)/\(words)")
        // Concurrent synthesis on the one synthesiser (presynthesis overlapping the reply) gives the same samples.
        let concurrent = try await withThrowingTaskGroup(of: (Int, [Float]).self) { g in
            for (i, c) in chunks.enumerated() { g.addTask { (i, try await tts.synthesize(c, voice: voice, speed: 1).samples) } }
            var r = [[Float]](repeating: [], count: chunks.count)
            for try await (i, s) in g { r[i] = s }
            return r
        }
        #expect(concurrent == sequential, "\(voice): concurrent synthesis matches sequential")
    }
}
