// M3.T04 step 2 (R-281 AC1; P-media-02 system framework): Basic dictation before the Voice pack — Apple's
// `SpeechTranscriber(locale:preset: .progressiveTranscription)` inside a `SpeechAnalyzer`, fed through
// `AnalyzerInput` (macOS 26 Speech; on-device). The locale must be supported and its assets installed
// (`AssetInventory.status(forModules:)` == .installed); the helper never starts an asset download — the app decides
// whether the system may install them (Offline only off) before it offers Basic dictation (BasicVoice). Otherwise
// `start` throws `voice.unavailable` and the MicButton shows the Voice pack install card.
// Partials: the finalized text so far + the current volatile result. Final: finalize through the end of input.
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Speech
import Synchronization

public final class SpeechAnalyzerBackend: SpeechBackend, @unchecked Sendable {
    public let engine: STTEngineID = .speechAnalyzer
    public let supportsPartials = true
    public var languages: Set<String> { [] }  // asked per locale (SpeechTranscriber.supportedLocales)

    private let state = Mutex(State())
    private var analyzer: SpeechAnalyzer?
    private var reader: Task<Void, Never>?
    private var locale = Locale(identifier: "en-US")

    struct State {
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var continuation: AsyncStream<STTEvent>.Continuation?
        var finalized: [String] = []
        var volatile = ""
        var lastPartial = ""
        var samples = 0
        var format: AVAudioFormat?
    }

    public init() {}

    /// The supported, installed locale equivalent to `locale` (nil = Basic dictation is unavailable for it).
    public static func readyLocale(_ locale: Locale?) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale ?? Locale.current) else { return nil }
        return await isInstalled(l) ? l : nil
    }

    /// The locale's on-device model is installed. `SpeechTranscriber.installedLocales` is the authority:
    /// `AssetInventory.status(forModules:)` reports `.supported` for some installed locales on macOS 26/27.
    public static func isInstalled(_ l: Locale) async -> Bool {
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) { return true }
        let t = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    public func start(locale requested: Locale?) async throws -> AsyncStream<STTEvent> {
        guard let l = await Self.readyLocale(requested) else {
            throw AntiChatError.voice("unavailable", "Basic dictation: no installed on-device model for \(requested?.identifier ?? "the system language")")
        }
        locale = l
        let transcriber = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (input, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        let (events, cont) = AsyncStream<STTEvent>.makeStream()
        state.withLock {
            $0 = State()
            $0.input = inputCont
            $0.continuation = cont
            $0.format = format
        }
        reader = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let text = String(r.text.characters)
                    self.state.withLock { s in
                        if r.isFinal {
                            s.finalized.append(text)
                            s.volatile = ""
                        } else {
                            s.volatile = text
                        }
                        let partial = Self.join(s.finalized + [s.volatile])
                        if !partial.isEmpty, partial != s.lastPartial {
                            s.lastPartial = partial
                            s.continuation?.yield(.partial(partial))
                        }
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: input)
        return events
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func append(samples: [Float]) {
        state.withLock { s in
            guard let input = s.input, let b = Self.buffer(samples, format: s.format) else { return }
            s.samples += samples.count
            input.yield(AnalyzerInput(buffer: b))
        }
    }

    /// 16 kHz mono Float32 samples in the analyzer's format (Int16 or Float32, 16 kHz mono).
    static func buffer(_ x: [Float], format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let f = format ?? VoiceAudioFormat.pcm
        guard !x.isEmpty, f.sampleRate == VoiceAudioFormat.sampleRate, f.channelCount == 1,
              let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(x.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(x.count)
        switch f.commonFormat {
        case .pcmFormatInt16:
            let d = b.int16ChannelData![0]
            for i in 0..<x.count { d[i] = Int16(max(-1, min(1, x[i].isNaN ? 0 : x[i])) * 32_767) }
        case .pcmFormatFloat32:
            x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        default: return nil
        }
        return b
    }

    public func finish() async throws -> FinalTranscript {
        state.withLock { s in
            s.input?.finish()
            s.input = nil
        }
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reader?.value
        let text = state.withLock { s -> String in
            s.continuation?.finish()
            s.continuation = nil
            return Self.join(s.finalized + [s.volatile])
        }
        return FinalTranscript(text: text, language: locale.language.languageCode?.identifier ?? "en", engine: .speechAnalyzer)
    }

    public func cancel() async {
        state.withLock { s in
            s.input?.finish()
            s.input = nil
        }
        await analyzer?.cancelAndFinishNow()
        reader?.cancel()
        await reader?.value
        state.withLock { s in
            s.continuation?.finish()
            s.continuation = nil
        }
    }
}
