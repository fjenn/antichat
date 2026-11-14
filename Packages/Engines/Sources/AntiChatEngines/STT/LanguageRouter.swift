// M3.T05 step 2 (R-284; P-media-05 adapter row 1): which recogniser hears which language.
//   setting = a language inside Parakeet's 25 → Parakeet;
//   setting = a language outside → WhisperKit with that language fixed;
//   setting = auto (nil) → Parakeet first; NLLanguageRecognizer on its transcript. Kept as is when the dominant language
//   is one of the user's languages (`Locale.preferredLanguages`) with p ≥ 0.80. Otherwise `WhisperKit.detectLanguage`
//   on the audio decides: a Parakeet language → Parakeet's transcript stays; any other → WhisperKit re-transcribes in it.
//   (AT-284 run 1: Parakeet turns Japanese / Chinese speech into Latin-script "Croatian" at p ≥ 0.9, so the transcript
//   alone cannot tell; the audio check runs only for speech outside the user's own languages.)
// The chosen language and engine travel in `FinalTranscript` (shown nowhere; logged at debug level without content).
// `RoutedBackend` is the SpeechBackend a full-voice dictation (and M3.T06 files) runs on: Parakeet partials while
// recording (WhisperKit's re-run window when the language is fixed outside the 25), the routing at finish. The
// WhisperKit model is leased on demand (`stt-multi`) only when the route needs it.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import NaturalLanguage
import Synchronization

public enum LanguageRouter {
    public static let autoThreshold = 0.80

    public enum Route: Sendable, Equatable {
        case parakeet
        case whisper(language: String)
        /// Parakeet first, then the transcript decides.
        case auto
    }

    /// The setting's base language code ("de-CH" → "de"); nil / "auto" / "" = auto.
    public static func base(_ setting: String?) -> String? {
        guard let s = setting?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "auto" else { return nil }
        return Locale(identifier: s).language.languageCode?.identifier.lowercased() ?? s.lowercased()
    }

    public static func route(setting: String?) -> Route {
        guard let lang = base(setting) else { return .auto }
        return ParakeetBackend.languageCodes.contains(lang) ? .parakeet : .whisper(language: lang)
    }

    /// Auto: the dominant language of Parakeet's transcript and its probability (NLLanguageRecognizer).
    public static func dominant(_ transcript: String) -> (language: String?, probability: Double) {
        let r = NLLanguageRecognizer()
        r.processString(transcript)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first else { return (nil, 0) }
        return (lang.rawValue.split(separator: "-").first.map(String.init), p)
    }

    /// The user's own languages (base codes of `Locale.preferredLanguages`).
    public static var userLanguages: Set<String> {
        Set(Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier.lowercased() })
    }

    /// Auto: keep Parakeet's transcript at once (true), or check the audio's language with WhisperKit (false).
    /// AT-284 (2026-11-05): Parakeet's own confidence separates its languages from speech it does not know — on the
    /// fixtures en/de ≥ 0.92, ja/zh/ar ≤ 0.80 (`parakeet-confidence.json`); garbage like "Dang so young kryung…" reads as
    /// English with NL p = 1.0 for 2 of 40 zh clips, so a confidence under 0.85 always asks WhisperKit about the audio.
    public static let keepConfidence: Float = 0.85

    public static func keepsParakeet(_ transcript: String, confidence: Float? = nil, userLanguages: Set<String> = userLanguages) -> Bool {
        if let confidence, confidence < keepConfidence { return false }
        let (lang, p) = dominant(transcript)
        guard let lang, !TranscriptText.isNonSpeech(transcript) else { return false }
        return userLanguages.contains(lang) && ParakeetBackend.languageCodes.contains(lang) && p >= autoThreshold
    }

    /// Auto, after the audio check: Parakeet stays for its own languages.
    public static func needsWhisper(detected: String) -> Bool { !ParakeetBackend.languageCodes.contains(detected.lowercased()) }
}

/// What the routed backend needs from WhisperKit (the real model, or a test double).
public protocol MultilingualRecognizer: Sendable {
    func transcribe(_ samples: [Float], language: String?) async throws -> WhisperKitModel.Result
    func detectLanguage(_ samples: [Float]) async throws -> (language: String, probability: Float)
}

extension WhisperKitModel: MultilingualRecognizer {}

public final class RoutedBackend: SpeechBackend, @unchecked Sendable {
    public typealias Lease = @Sendable () async throws -> (any MultilingualRecognizer, @Sendable () async -> Void)

    public var engine: STTEngineID { routedEngine.withLock { $0 } }
    public let supportsPartials = true
    public var languages: Set<String> { ParakeetBackend.languageCodes }

    private let parakeet: any SpeechBackend
    private let whisper: Lease
    private let setting: String?
    private let routedEngine = Mutex(STTEngineID.parakeet)
    private let audio = Mutex<[Float]>([])
    private var whisperLease: (any MultilingualRecognizer, @Sendable () async -> Void)?
    private var fixedWhisper: WhisperPartials?

    private let whisperInstalled: Bool

    /// `setting` = Settings → Voice → Spoken language (nil / "auto" = auto). Without `stt-multi` installed, auto keeps
    /// Parakeet's transcript (a fixed language outside the 25 is `voice.unavailable`).
    public init(parakeet: any SpeechBackend, whisper: @escaping Lease, setting: String?, whisperInstalled: Bool = true) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.setting = setting
        self.whisperInstalled = whisperInstalled
    }

    public func start(locale: Locale?) async throws -> AsyncStream<STTEvent> {
        audio.withLock { $0 = [] }
        switch LanguageRouter.route(setting: setting) {
        case .whisper(let lang):
            routedEngine.withLock { $0 = .whisperkit }
            let lease = try await whisper()
            whisperLease = lease
            let p = WhisperPartials(model: lease.0, language: lang)
            fixedWhisper = p
            return p.start()
        case .parakeet, .auto:
            return try await parakeet.start(locale: LanguageRouter.base(setting).map(Locale.init(identifier:)) ?? locale)
        }
    }

    public func append(samples: [Float]) {
        audio.withLock { $0 += samples }
        if let fixedWhisper { fixedWhisper.append(samples) } else { parakeet.append(samples: samples) }
    }

    public func finish() async throws -> FinalTranscript {
        defer { Task { [lease = whisperLease] in await lease?.1() } }
        let samples = audio.withLock { $0 }
        if let fixedWhisper {
            await fixedWhisper.stop()
            let lang = LanguageRouter.base(setting)
            let r = try await whisperLease!.0.transcribe(samples, language: lang)
            return FinalTranscript(text: r.text, language: lang ?? r.language, engine: .whisperkit, segments: r.segments)
        }
        let first = try await parakeet.finish()
        let keep = { (lang: String?) in
            FinalTranscript(text: first.text, language: LanguageRouter.base(self.setting) ?? lang ?? first.language, engine: .parakeet,
                            segments: first.segments)
        }
        guard whisperInstalled, LanguageRouter.route(setting: setting) == .auto, samples.count >= 16_000,
              !LanguageRouter.keepsParakeet(first.text, confidence: first.confidence) else { return keep(LanguageRouter.dominant(first.text).language) }
        let lease = try await whisper()
        whisperLease = lease
        // The whole audio (trimming quiet edges dropped quiet speech and emptied 7 of 40 Japanese results, AT-284 run 2).
        let detected = try await lease.0.detectLanguage(samples)
        guard LanguageRouter.needsWhisper(detected: detected.language) else { return keep(detected.language) }
        let r = try await lease.0.transcribe(samples, language: detected.language)
        routedEngine.withLock { $0 = .whisperkit }
        AppLog.log(.voice, .debug, "LanguageRouter auto → whisperkit \(detected.language) (p \(String(format: "%.2f", detected.probability)))")
        return FinalTranscript(text: r.text, language: detected.language, engine: .whisperkit, segments: r.segments)
    }

    /// NFR-V1: Parakeet's transcript so far, only when `finish` would keep it (a turn that auto-routing would hand to
    /// WhisperKit, or a fixed WhisperKit language, has none: its final comes from `finish`).
    public func provisional() async throws -> FinalTranscript? {
        guard fixedWhisper == nil, let first = try await parakeet.provisional() else { return nil }
        let samples = audio.withLock { $0.count }
        if whisperInstalled, LanguageRouter.route(setting: setting) == .auto {
            // `finish` routes on the turn's audio including its trailing silence: a turn still under 1 s at the pause
            // may be ≥ 1 s there and go to WhisperKit, so no early final for it (M3 review finding 10).
            if samples < 16_000 { return nil }
            if !LanguageRouter.keepsParakeet(first.text, confidence: first.confidence) { return nil }
        }
        return FinalTranscript(text: first.text, language: LanguageRouter.base(setting) ?? LanguageRouter.dominant(first.text).language ?? first.language,
                               engine: .parakeet, segments: first.segments)
    }

    public func cancel() async {
        if let fixedWhisper { await fixedWhisper.stop() } else { await parakeet.cancel() }
        await whisperLease?.1()
        whisperLease = nil
    }
}

/// WhisperKit partials for a fixed non-Parakeet language: the open part re-run every 500 ms (PartialWindow).
final class WhisperPartials: @unchecked Sendable {
    let model: any MultilingualRecognizer
    let language: String
    private let state = Mutex<(samples: [Float], window: PartialWindow, cont: AsyncStream<STTEvent>.Continuation?, last: String)>(([], PartialWindow(), nil, ""))
    private var task: Task<Void, Never>?

    init(model: any MultilingualRecognizer, language: String) {
        self.model = model
        self.language = language
    }

    func start() -> AsyncStream<STTEvent> {
        let (s, c) = AsyncStream<STTEvent>.makeStream()
        state.withLock { $0.cont = c }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PartialWindow.interval)
                guard let self, !Task.isCancelled else { return }
                let job = self.state.withLock { st -> [Float]? in
                    guard st.window.nextPartial(count: st.samples.count) != nil else { return nil }
                    return Array(st.samples.suffix(PartialWindow.maxSeconds * PartialWindow.sampleRate))  // ≤ 30 s per run
                }
                guard let job, let r = try? await self.model.transcribe(job, language: self.language) else { continue }
                self.state.withLock { st in
                    guard !r.text.isEmpty, r.text != st.last else { return }
                    st.last = r.text
                    st.cont?.yield(.partial(r.text))
                }
            }
        }
        return s
    }

    func append(_ x: [Float]) { state.withLock { $0.samples += x } }

    func stop() async {
        task?.cancel()
        await task?.value
        state.withLock { st in
            st.cont?.finish()
            st.cont = nil
        }
    }
}
