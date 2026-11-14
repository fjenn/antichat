// M3.T04 step 3 (R-281, D-010; P-media-02 system framework): Basic voice read aloud through `AVSpeechSynthesizer`,
// in the helper (it owns playback, contract 1). Voices: `AVSpeechSynthesisVoice.speechVoices()` filtered to the
// spoken language; the user rate 0.75×–1.5× maps to `AVSpeechUtteranceDefaultSpeechRate × factor` (clamped to the
// synthesiser's range). `.silent` renders through `write(_:toBufferCallback:)` and plays nothing (unit tests: no
// speakers in tests). The M0 spike's `SystemTTS` (V1 probe) stays until M3.T09–T11 replace it.
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import Foundation
import Synchronization

public final class SystemVoiceBackend: NSObject, TTSBackend, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public enum Output: Sendable { case speakers, silent }

    public let output: Output
    private let synth = AVSpeechSynthesizer()
    private let state = Mutex(State())

    struct State {
        var stopped = false
        var playing: CheckedContinuation<Bool, Never>?
        var playedMs: Double = 0
        var startedAt: ContinuousClock.Instant?
    }

    public init(output: Output = .speakers) {
        self.output = output
        super.init()
        synth.delegate = self
    }

    deinit {
        synth.delegate = nil  // never leave TextToSpeech a dangling delegate
        SpeechSynthesizerKeeper.retire(synth)
    }

    public var voices: [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { VoiceInfo(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    /// The system voices for `language` (BCP-47 or its base code), best quality first.
    public static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let base = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased() == language.lowercased() || $0.language.lowercased().hasPrefix(base + "-") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    /// The utterance rate for the user factor 0.75…1.5.
    public static func rate(_ factor: Float) -> Float {
        let f = min(1.5, max(0.75, factor))
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * f))
    }

    /// `voice` = a system voice identifier, or a language ("en-US"), or "" (the system language).
    static func resolve(_ voice: String) -> AVSpeechSynthesisVoice? {
        if let v = AVSpeechSynthesisVoice(identifier: voice) { return v }
        // A Kokoro id (Settings › Voice chose it while the Voice pack was installed) = the system language's voice.
        let kokoro = KokoroVoices.english.contains { $0.id == voice }
        let lang = voice.isEmpty || kokoro ? AVSpeechSynthesisVoice.currentLanguageCode() : voice
        return voices(for: lang).first ?? AVSpeechSynthesisVoice(language: lang)
    }

    public func speak(_ chunks: AsyncStream<TTSChunk>, voice: String, rate: Float) -> AsyncStream<TTSEvent> {
        state.withLock { $0 = State() }
        let (events, cont) = AsyncStream<TTSEvent>.makeStream()
        let v = Self.resolve(voice), r = Self.rate(rate)
        Task {
            var stopped = false
            for await chunk in chunks {
                if state.withLock({ $0.stopped }) { stopped = true; break }
                let u = AVSpeechUtterance(string: chunk.text)
                u.voice = v
                u.rate = r
                cont.yield(.started(chunk: chunk.index))
                let finished = await play(u)
                cont.yield(.played(ms: state.withLock { $0.playedMs }))
                if !finished { stopped = true; break }
            }
            cont.yield(.finished(stopped: stopped || state.withLock { $0.stopped }))
            cont.finish()
        }
        return events
    }

    public func stop() {
        state.withLock { $0.stopped = true }
        if output == .speakers { synth.stopSpeaking(at: .immediate) }
        resume(false)
    }

    /// Plays one utterance; false when stopped.
    private func play(_ u: AVSpeechUtterance) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let stoppedAlready = state.withLock { s -> Bool in
                if s.stopped { return true }
                s.playing = c
                return false
            }
            if stoppedAlready { return c.resume(returning: false) }
            switch output {
            case .speakers:
                state.withLock { $0.startedAt = .now }
                synth.speak(u)
            case .silent:
                synth.write(u) { [weak self] buffer in
                    guard let self else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return self.resume(true) }
                    self.state.withLock { $0.playedMs += Double(pcm.frameLength) / pcm.format.sampleRate * 1000 }
                }
            }
        }
    }

    private func resume(_ finished: Bool) {
        let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            if let t = s.startedAt {
                let d = ContinuousClock.now - t
                s.playedMs += Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                s.startedAt = nil
            }
            defer { s.playing = nil }
            return s.playing
        }
        c?.resume(returning: finished)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { resume(true) }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { resume(false) }
}
