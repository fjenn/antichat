// M3.T05 step 1 (R-284; P-media-05): WhisperKit large-v3 turbo (`stt-multi`, 632 MB, on demand) for languages outside
// Parakeet's 25. Loaded from the model store only — `WhisperKitLocal.config` (download: false, tokenizer from the
// model folder; D-11) — and through the scheduler (`stt-multi` → residency `.stt`, idle unload per NFR-M2).
// API at argmaxinc/argmax-oss-swift@1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4:
//   Sources/WhisperKit/Core/WhisperKit.swift:62 `init(_ config:)`, :533/:546 `detectLanguage` / `detectLangauge(audioArray:)`
//   (the upstream spelling), :993 `transcribe(audioArray:decodeOptions:)`.
// Not streaming: partials come from re-running on the open part every 500 ms (PartialWindow); the final is one pass.
//
// Hallucination control (AT-284 / NFR-V9; `WhisperDecodePolicy`) = the Whisper reference decoder's hygiene
// (openai/whisper `transcribe.py` / `decoding.py`): temperature fallback 0 → 1 in 0.2 steps on compression ratio > 2.4
// or mean logprob < −1 (first-token logprob −1.5), no-speech threshold 0.6, `suppress_tokens="-1"` (the tokenizer's
// non-speech symbol set: music notes, brackets, "<<", "--" …) and `suppress_blank`, condition_on_previous_text off
// (WhisperKit carries no previous-window prompt; each window decodes on its own). WhisperKit implements every threshold
// except the no-speech probability (TextDecoder.swift:821 `noSpeechProb = 0`), so Silero VAD stands in for it: the
// audio is level-normalised, trimmed to the voiced span (lead/trail non-speech is where Whisper invents subtitle
// sign-offs), and segments that start after the voiced span are dropped.
// Empty-decode rescue (M9.T05, NFR-V9 ar): WhisperKit's `firstTokenLogProbThreshold` (−1.5; not in the reference decoder)
// stops a decode at its first token and, when every fallback temperature trips it too, returns no text at all — on
// FLEURS ar/28 every variant (legacy included) gave "" for 6.4 s of clear speech, 12 of ar's 83 word errors. When the
// VAD found speech and the decode came back empty, it runs once more without that threshold (the reference decoder's
// rule); every other threshold stays. Audio the VAD calls non-speech is never re-decoded.
// This is decoding hygiene, not a content filter (R-241 / D-005; A-M3-06): the suppressed ids are punctuation/symbol
// tokens that are never speech, so no word the speaker said can be removed or replaced — it stops the decoder from
// inventing text. There is no word or phrase list (a "thank you" phrase list could eat real speech); the r241 audit
// allow-list carries one scoped entry for the `suppressTokens` line of this file.
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import WhisperKit

/// How `WhisperKitModel` decodes. `.standard` is the product setting; the switches exist for the AT-284 probe.
public struct WhisperDecodePolicy: Sendable, Codable, Hashable {
    /// Peak-normalise quiet recordings (gain ≤ +30 dB, peak −3 dBFS) before VAD and decode.
    public var normalizeLevel = true
    /// Trim leading / trailing non-speech (Silero VAD, energy gate without it) before decode.
    public var trimSilence = true
    /// openai/whisper `suppress_tokens="-1"` (non-speech symbol ids) + `suppress_blank` (no blank first token).
    public var suppressNonSpeech = true
    /// Drop decoded segments that start after the voiced span (the VAD's no-speech decision).
    public var dropSilentSegments = true
    /// Reference temperature fallback (WhisperKit default: 5 × 0.2).
    public var temperatureFallbackCount = 5
    /// Word timings in `Result.words` (diagnostics; costs the alignment pass).
    public var wordTimestamps = false
    /// An empty decode of audio the VAD calls speech runs once more without WhisperKit's first-token log-prob threshold
    /// (the reference decoder has none; see the file header).
    public var rescueEmptyDecode = true

    public static let standard = WhisperDecodePolicy()
    /// The M3.T05 behaviour (WhisperKit defaults), kept for the probe's baseline.
    public static let legacy = WhisperDecodePolicy(normalizeLevel: false, trimSilence: false, suppressNonSpeech: false,
                                                   dropSilentSegments: false, rescueEmptyDecode: false)

    public init(normalizeLevel: Bool = true, trimSilence: Bool = true, suppressNonSpeech: Bool = true,
                dropSilentSegments: Bool = true, temperatureFallbackCount: Int = 5, rescueEmptyDecode: Bool = true) {
        self.normalizeLevel = normalizeLevel
        self.trimSilence = trimSilence
        self.suppressNonSpeech = suppressNonSpeech
        self.dropSilentSegments = dropSilentSegments
        self.temperatureFallbackCount = temperatureFallbackCount
        self.rescueEmptyDecode = rescueEmptyDecode
    }
}

/// The resident WhisperKit pipeline (materialized by `VoiceModelResidency` for key `stt-multi`).
public actor WhisperKitModel {
    private let kit: WhisperKit
    private let vad: SileroFrameVAD?
    private let nonSpeech: [Int]
    public var policy: WhisperDecodePolicy

    /// `directory` = the install view; the Core ML folder may sit one level down (the HF repo layout). Silero VAD
    /// comes from the sibling `vad-files` install (same Voice pack); without it the trim falls back to an energy gate.
    public static func load(directory: URL, policy: WhisperDecodePolicy = .standard) async throws -> WhisperKitModel {
        let fm = FileManager.default
        let sub = (try? fm.contentsOfDirectory(atPath: directory.path))?.first { $0.hasPrefix("openai_whisper-") }
        let folder = sub.map { directory.appendingPathComponent($0) } ?? directory
        // The tokenizer sits in the model folder (dev store) or in the required catalog key `stt-multi-tok`, whose
        // install view is a sibling of this one.
        let sibling = directory.deletingLastPathComponent().appendingPathComponent("stt-multi-tok")
        let tokenizer = [folder, directory, sibling].first { fm.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path) }
        guard let tokenizer else { throw AntiChatError.voice("modelMissing", "stt-multi tokenizer") }
        let kit = try await WhisperKit(WhisperKitLocal.config(modelFolder: folder, tokenizerFolder: tokenizer))
        let vadDir = directory.deletingLastPathComponent().appendingPathComponent("vad-files")
        let vad = try? SileroFrameVAD(directory: vadDir, computeUnits: .cpuAndNeuralEngine)
        let ids = kit.tokenizer.map { t in WhisperNonSpeech.tokens { t.encode(text: $0) } } ?? []
        return WhisperKitModel(kit: kit, vad: vad, nonSpeech: ids, policy: policy)
    }

    private init(kit: WhisperKit, vad: SileroFrameVAD?, nonSpeech: [Int], policy: WhisperDecodePolicy) {
        self.kit = kit
        self.vad = vad
        self.nonSpeech = nonSpeech
        self.policy = policy
    }

    public func setPolicy(_ p: WhisperDecodePolicy) { policy = p }

    public struct Result: Sendable {
        public var text: String
        public var language: String
        public var segments: [TranscriptSegment]
        /// Word timings with probability (only with `policy.wordTimestamps`), plus the voiced span end (s).
        public var words: [(word: String, start: Double, end: Double, probability: Float)] = []
        public var voicedEnd: Double = 0
    }

    /// `language` nil = WhisperKit detects it. Segment times are on the caller's timeline (trim offset added back).
    public func transcribe(_ samples: [Float], language: String?) async throws -> Result {
        let p = policy
        var audio = p.normalizeLevel ? SpeechSpan.normalized(samples) : samples
        var offset = 0
        var voicedEnd = Double(audio.count) / 16_000
        var speechFound = false
        if p.trimSilence || p.dropSilentSegments || p.rescueEmptyDecode {
            let probs = voiceProbabilities(audio)
            if let span = SpeechSpan.voiced(probabilities: probs, frame: SileroFrameVAD.frame, count: audio.count) {
                speechFound = true
                if p.trimSilence {
                    offset = span.lowerBound
                    audio = Array(audio[span])
                }
                voicedEnd = Double(span.upperBound - offset) / 16_000
            }
        }
        var o = DecodingOptions(language: language, temperatureFallbackCount: p.temperatureFallbackCount,
                                detectLanguage: language == nil, skipSpecialTokens: true)
        // The reference thresholds, set explicitly (they are WhisperKit's defaults today; a default change upstream
        // must not silently change decoding).
        o.compressionRatioThreshold = 2.4
        o.logProbThreshold = -1.0
        o.firstTokenLogProbThreshold = -1.5
        o.noSpeechThreshold = 0.6
        if p.suppressNonSpeech {
            o.suppressBlank = true
            o.suppressTokens = nonSpeech
        }
        o.wordTimestamps = p.wordTimestamps
        o.chunkingStrategy = audio.count > 30 * 16_000 ? .vad : nil
        let input = audio, end = voicedEnd
        func decode(_ o: DecodingOptions) async throws -> ([TranscriptionResult], [(start: Double, end: Double, text: String)]) {
            let rs = try await kit.transcribe(audioArray: input, decodeOptions: o)
            var segs = rs.flatMap(\.segments).map { (start: Double($0.start), end: Double($0.end), text: Self.clean($0.text)) }
                .filter { !$0.text.isEmpty }
            if p.dropSilentSegments {
                // A segment that starts after the voiced span (+ 0.3 s) transcribes no speech.
                segs = segs.filter { $0.start < end + 0.3 || segs.count == 1 }
            }
            return (rs, segs)
        }
        var (rs, segs) = try await decode(o)
        if segs.isEmpty, p.rescueEmptyDecode, speechFound, o.firstTokenLogProbThreshold != nil {
            o.firstTokenLogProbThreshold = nil
            (rs, segs) = try await decode(o)
        }
        let lang = rs.first?.language ?? language ?? ""
        let shift = Double(offset) / 16_000
        let out = segs.map { TranscriptSegment(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
        let text = segs.map(\.text).joined(separator: Self.joiner(lang)).trimmingCharacters(in: .whitespacesAndNewlines)
        let shiftF = Float(shift)
        let words = rs.flatMap(\.segments).flatMap { $0.words ?? [] }
            .map { (word: $0.word, start: Double($0.start + shiftF), end: Double($0.end + shiftF), probability: $0.probability) }
        return Result(text: text, language: lang, segments: out, words: words, voicedEnd: voicedEnd + shift)
    }

    /// The spoken language of (the first 30 s of) `samples` and its probability.
    public func detectLanguage(_ samples: [Float]) async throws -> (language: String, probability: Float) {
        let audio = policy.normalizeLevel ? SpeechSpan.normalized(samples) : samples
        let r = try await kit.detectLangauge(audioArray: Array(audio.prefix(30 * 16_000)))
        return (r.language, r.langProbs[r.language] ?? 0)
    }

    /// Silero speech probability per 512-sample frame (energy proxy without the model).
    private func voiceProbabilities(_ x: [Float]) -> [Float] {
        let n = SileroFrameVAD.frame
        var out: [Float] = []
        out.reserveCapacity(x.count / n)
        vad?.reset()
        var i = 0
        while i + n <= x.count {
            let f = x[i ..< i + n]
            if let vad, let pr = try? vad.probability(f) {
                out.append(pr)
            } else {
                out.append(rmsDBFS(Array(f)) >= -45 ? 1 : 0)
            }
            i += n
        }
        return out
    }

    /// Whisper segments of a script without word spaces join without one.
    static func joiner(_ lang: String) -> String { ["ja", "zh", "yue", "th", "lo", "my", "km"].contains(lang) ? "" : " " }

    /// Drops WhisperKit's special-token leftovers ("<|en|>", "<|0.00|>").
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Voiced span and level normalisation (pure; unit-tested).
public enum SpeechSpan {
    /// Silero frames ≥ `threshold` in runs of ≥ `minRun` frames; the span from the first to the last such run, padded
    /// `lead` / `trail` seconds. nil when nothing is voiced (the caller then decodes the whole audio: an empty result
    /// is worse than a hallucinated one when the VAD misses quiet speech).
    public static func voiced(probabilities p: [Float], frame: Int, count: Int, threshold: Float = 0.5, minRun: Int = 3,
                              lead: Double = 0.25, trail: Double = 0.45, sampleRate: Int = 16_000) -> Range<Int>? {
        var runs: [(Int, Int)] = []
        var i = 0
        while i < p.count {
            guard p[i] >= threshold else { i += 1; continue }
            var j = i
            while j < p.count, p[j] >= threshold - 0.15 { j += 1 }
            if j - i >= minRun { runs.append((i, j)) }
            i = j
        }
        guard let first = runs.first, let last = runs.last else { return nil }
        let lo = max(0, first.0 * frame - Int(lead * Double(sampleRate)))
        let hi = min(count, last.1 * frame + Int(trail * Double(sampleRate)))
        return lo < hi ? lo ..< hi : nil
    }

    /// Peak-normalised to `peakDBFS` with the gain capped at `maxGainDB` (never attenuates).
    public static func normalized(_ x: [Float], peakDBFS: Double = -3, maxGainDB: Double = 30) -> [Float] {
        let peak = x.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return x }
        let target = Float(pow(10, peakDBFS / 20))
        let gain = min(target / peak, Float(pow(10, maxGainDB / 20)))
        return gain > 1 ? x.map { $0 * gain } : x
    }
}

/// openai/whisper `tokenizer.non_speech_tokens` (the `suppress_tokens="-1"` set): symbol tokens that are never speech.
/// Decoding hygiene (see the file header), not a content filter: no letter, digit or sentence punctuation is in it.
enum WhisperNonSpeech {
    static let symbols: [String] = Array("\"#()*+/:;<=>@[\\]^_`{|}~「」『』").map(String.init)
        + "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
    static let miscellaneous = Set("♩♪♫♬♭♮♯".map(String.init))

    /// Token ids of every symbol (alone or after a space) that encodes to one token; plus " -" and " '".
    static func tokens(encode: (String) -> [Int]) -> [Int] {
        var out = Set<Int>()
        let dash = encode(" -"), quote = encode(" '")
        if let d = dash.first { out.insert(d) }
        if let q = quote.first { out.insert(q) }
        for s in symbols + miscellaneous.sorted() {
            for t in [encode(s), encode(" " + s)] {
                if t.count == 1 || (miscellaneous.contains(s) && !t.isEmpty) { out.insert(t[0]) }
            }
        }
        return out.sorted()
    }
}
