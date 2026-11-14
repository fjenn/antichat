// AT-284 follow-up (NFR-V9): the pure parts of WhisperKit's hallucination control — the voiced span (Silero
// probabilities → trim with padding; nothing voiced → no trim), level normalisation (gain capped, never attenuates)
// and openai/whisper's non-speech suppress set (symbols only: never a letter or sentence punctuation).
//   make test-unit FILTER=WhisperDecodePolicyTests
import Foundation
import Testing

@testable import AntiChatEngines

struct WhisperDecodePolicyTests {
    @Test func voicedSpanTrimsLeadAndTrailWithPadding() {
        // 32 ms frames: 10 silent, 50 voiced (one 1-frame dip), 20 silent.
        var p = [Float](repeating: 0.02, count: 10) + [Float](repeating: 0.9, count: 50) + [Float](repeating: 0.02, count: 20)
        p[30] = 0.4  // inside the hysteresis band (≥ 0.35): stays speech
        let r = SpeechSpan.voiced(probabilities: p, frame: 512, count: 80 * 512)!
        #expect(r.lowerBound == 10 * 512 - 4_000)
        #expect(r.upperBound == 60 * 512 + 7_200)
        #expect(SpeechSpan.voiced(probabilities: [Float](repeating: 0.1, count: 40), frame: 512, count: 40 * 512) == nil)
        // A 2-frame blip is not speech (minRun 3).
        #expect(SpeechSpan.voiced(probabilities: [0, 0.9, 0.9, 0, 0], frame: 512, count: 5 * 512) == nil)
    }

    @Test func normalisationLiftsQuietAudioOnly() {
        let quiet = [Float](repeating: 0.003, count: 100)  // ≈ −50 dBFS
        let n = SpeechSpan.normalized(quiet)
        #expect(abs(n[0] - 0.003 * pow(10, 30 / 20)) < 1e-4, "gain capped at +30 dB")
        let loud = [Float](repeating: 0.9, count: 10)
        #expect(SpeechSpan.normalized(loud) == loud, "never attenuates")
    }

    @Test func nonSpeechSetHasTheReferenceSymbols() {
        // A toy tokenizer: one id per distinct string.
        var table: [String: Int] = [:]
        let ids = WhisperNonSpeech.tokens { s in
            if let v = table[s] { return [v] }
            table[s] = table.count + 1
            return [table[s]!]
        }
        #expect(ids.count == Set(ids).count)
        #expect(table[" -"] != nil && table["♪"] != nil && table["「"] != nil && table[" ("] != nil)
        #expect(table["a"] == nil && table["。"] == nil && table["."] == nil && table[","] == nil,
                "letters and sentence punctuation are never suppressed")
    }

    @Test func standardPolicyKeepsTheReferenceSafeguards() {
        let p = WhisperDecodePolicy.standard
        #expect(p.suppressNonSpeech && p.trimSilence && p.dropSilentSegments && p.temperatureFallbackCount == 5)
        #expect(!WhisperDecodePolicy.legacy.suppressNonSpeech)
        // M9.T05: an empty decode of VAD-voiced audio is retried without WhisperKit's first-token threshold.
        #expect(p.rescueEmptyDecode && !WhisperDecodePolicy.legacy.rescueEmptyDecode)
    }
}
