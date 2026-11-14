// M3.T03 step 1 (G-036; R-050): one recogniser behind dictation, voice turns and files. Parakeet (this task),
// WhisperKit (M3.T05, languages outside Parakeet's 25) and SpeechAnalyzer (M3.T04, Basic voice) implement it; the
// session picks one at start and never switches mid-session (M3 contract 5).
// Audio in is always `VoiceAudioFormat` (16 kHz mono Float32). The task text names `append(_ pcm: AVAudioPCMBuffer)`;
// the capture tap already yields converted samples, so the protocol takes `[Float]` and the buffer form is an
// extension (no per-frame buffer allocation on the capture path).
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import Foundation

public enum STTEvent: Sendable, Hashable {
    /// The whole transcript so far (replaces the previous partial).
    case partial(String)
    /// English streaming EOU on T1+; the turn detector ends immediately on this signal.
    case endOfUtterance
}

public protocol SpeechBackend: AnyObject, Sendable {
    var engine: STTEngineID { get }
    var supportsPartials: Bool { get }
    /// BCP-47 base codes this backend recognises (Parakeet: its 25 European languages).
    var languages: Set<String> { get }
    /// Opens one utterance; partials arrive on the stream until `finish` / `cancel`.
    func start(locale: Locale?) async throws -> AsyncStream<STTEvent>
    /// 16 kHz mono samples, in capture order.
    func append(samples: [Float])
    /// Ends the utterance: the final transcript of everything appended (the partial stream finishes).
    func finish() async throws -> FinalTranscript
    /// Drops the utterance without a final.
    func cancel() async
    /// The transcript of everything appended so far, the utterance staying open (default: nil, unsupported).
    func provisional() async throws -> FinalTranscript?
}

extension SpeechBackend {
    /// NFR-V1: the final transcript of everything appended so far, without ending the utterance (the voice session
    /// asks at a pause and reuses it when the turn ends with nothing voiced after it). nil = not supported.
    public func provisional() async throws -> FinalTranscript? { nil }

    /// A 16 kHz mono Float32 buffer (`VoiceAudioFormat.pcm`).
    public func append(_ pcm: AVAudioPCMBuffer) { append(samples: VoiceAudioConverter.samples(pcm)) }
}

/// Transcript text that carries no words: empty, whitespace, or only bracketed non-speech tags / punctuation
/// ("[noise]", "<unk>", "…"). R-050 AC3: such a dictation returns to an empty composer.
public enum TranscriptText {
    public static func isNonSpeech(_ text: String) -> Bool {
        var t = text
        for (open, close) in [("[", "]"), ("<", ">"), ("(", ")")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return !t.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
}
