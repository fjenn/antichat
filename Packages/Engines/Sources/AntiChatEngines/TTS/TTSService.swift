// M3.T01 skeleton → M3.T04 Basic read aloud (G-038; R-281). The helper's text-to-speech entry points that
// `VoiceService` routes read aloud and voice previews to. The backend is chosen when the speech starts
// (VoiceBackendSelector): without the verified Voice pack, Basic voice = `SystemVoiceBackend` (AVSpeechSynthesizer);
// with it, Kokoro on the ANE (M3.T07, `KokoroBackend`; the system voice on macOS 26.4–26.5, K-NEW-ENG-9).
// One speech: markdown → speakable text (`SpeakableText`) → clause-first chunks (`ClauseChunker`) → `ttsStarted(chunk)` per
// sentence → `ttsStopped(playedMs, finished | stopped)` → `done`. The request lives until the speech ends (the router
// closes a request whose body returns); `SpeakStop` stops it at once — M3 review P1-2: also while Kokoro is still
// leasing (seconds when cold): the speech is registered from `prepare` (or the start of `speak`) and a stop before it
// plays ends it with `ttsStopped(.stopped)` without a sound.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import OsaurusVendored
import Synchronization

public protocol TTSServing: Sendable {
    /// Speaks `request.text`; emits `ttsStarted` / `ttsStopped`, then `done`.
    func speak(_ request: Speak, models: VoiceModelSet, emit: @escaping VoiceEmit) async
    /// Stops the speech `stop.requestID` (≤ 200 ms, R-054 AC1); its stream ends with `ttsStopped(.stopped)`.
    func stop(_ stop: SpeakStop) async
    /// The speech `id` was routed (synchronous, before `speak`): a stop for it is kept from now on.
    func prepare(_ id: UUID)
}

extension TTSServing {
    public func prepare(_ id: UUID) {}
}

public final class TTSService: TTSServing {
    public typealias BasicFactory = @Sendable () -> any TTSBackend
    public typealias KokoroFactory = @Sendable (any SpeechSynthesizing) -> KokoroBackend
    private let basic: BasicFactory?
    private let provider: (any VoiceModelProvider)?
    private let kokoro: KokoroFactory
    private let speeches = SpeechTable()
    private let osGateLogged = Mutex(false)

    enum Speech {
        /// Routed, not playing yet (models leasing); `stopped` = a SpeakStop came first.
        case starting(stopped: Bool)
        case running(any TTSBackend)
    }

    final class SpeechTable: Sendable {
        let m = Mutex<[UUID: Speech]>([:])
        func withLock<R>(_ body: (inout [UUID: Speech]) -> R) -> R { m.withLock { body(&$0) } }
    }

    /// `basic` nil = no speech output in this process (unit-test default): every speech answers `voice.unavailable`.
    /// `provider` leases the `tts` slot (Kokoro, M3.T07); nil = Kokoro unavailable here.
    public init(basic: BasicFactory? = nil, provider: (any VoiceModelProvider)? = nil,
                kokoro: @escaping KokoroFactory = { KokoroBackend(tts: $0, output: .speakers) }) {
        self.basic = basic
        self.provider = provider
        self.kokoro = kokoro
    }

    /// The helper's service: Kokoro through the scheduler with the verified pack, Basic voice otherwise; both play
    /// through the speakers.
    public static func helper(provider: (any VoiceModelProvider)? = nil) -> TTSService {
        TTSService(basic: { SystemVoiceBackend(output: .speakers) }, provider: provider)
    }

    public func prepare(_ id: UUID) {
        speeches.withLock { if $0[id] == nil { $0[id] = .starting(stopped: false) } }
    }

    public func speak(_ request: Speak, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        prepare(request.requestID)
        defer { _ = speeches.withLock { $0.removeValue(forKey: request.requestID) } }
        switch VoiceBackendSelector.tts(models) {
        case .full where KokoroBackend.osAllowsKokoro():
            guard let provider, let slot = models.slots[.tts] else {
                return emit([.engine(.error(.voice("unavailable", "no Kokoro voice service in this process")))])
            }
            let lease: VoiceModelLease
            do { lease = try await provider.lease(.tts, slot) } catch {
                return emit([.engine(.error(error as? AntiChatError ?? .voice("modelMissing", "tts")))])
            }
            guard let synth = lease.object as? any SpeechSynthesizing else {
                await lease.release()
                return emit([.engine(.error(.voice("modelMismatch", "tts")))])
            }
            #if DEBUG || ANTICHAT_PERF_HARNESS  // M9.T05 bench (NFR-V8): a silent clock instead of the speakers
            let backend = request.silentOutput == true ? KokoroBackend(tts: synth, output: .silent) : kokoro(synth)
            #else
            let backend = kokoro(synth)
            #endif
            await run(backend, request, emit: emit)
            await lease.release()
        case .full, .basic:
            if VoiceBackendSelector.tts(models) == .full, !osGateLogged.withLock({ l in defer { l = true }; return l }) {
                AppLog.log(.voice, .notice, "tts.osGate: Kokoro off on this macOS (K-NEW-ENG-9), system voice instead")
            }
            guard let basic else { return emit([.engine(.error(.voice("unavailable", "no speech output in this process")))]) }
            await run(basic(), request, emit: emit)
        }
    }

    private func run(_ backend: any TTSBackend, _ request: Speak, emit: @escaping VoiceEmit) async {
        // A stop that came while the model leased (or a cancelled request): nothing plays.
        let stoppedEarly = speeches.withLock { t -> Bool in
            if case .starting(stopped: true)? = t[request.requestID] { return true }
            t[request.requestID] = .running(backend)
            return false
        }
        if stoppedEarly || Task.isCancelled {
            return emit([.voice(.ttsStopped(playedMs: 0, reason: .stopped)), .engine(.done(.stop))])
        }
        // M3.T07: Markdown never spoken (SpeakableText; fences → "code omitted"), clause-first chunks (ClauseChunker).
        let sentences = ClauseChunker.chunks(SpeakableText.from(markdown: request.text,
                                                                codeOmitted: request.codeOmitted ?? SpeakableText.defaultCodeOmitted))
        let chunks = AsyncStream<TTSChunk> { c in
            for (i, s) in sentences.enumerated() { c.yield(TTSChunk(index: i, text: s)) }
            c.finish()
        }
        var played: Double = 0
        await withTaskCancellationHandler {
            for await e in backend.speak(chunks, voice: request.voiceID, rate: request.rate) {
                switch e {
                case .started(let i): emit([.voice(.ttsStarted(chunkIndex: i))])
                case .played(let ms): played = ms
                case .finished(let stopped):
                    emit([.voice(.ttsStopped(playedMs: played, reason: stopped ? .stopped : .finished)), .engine(.done(.stop))])
                }
            }
        } onCancel: {
            backend.stop()
        }
    }

    public func stop(_ stop: SpeakStop) async {
        let backend = speeches.withLock { t -> (any TTSBackend)? in
            switch t[stop.requestID] {
            case .running(let b)?: return b
            case .starting?:
                t[stop.requestID] = .starting(stopped: true)
                return nil
            case nil: return nil
            }
        }
        backend?.stop()
    }
}
