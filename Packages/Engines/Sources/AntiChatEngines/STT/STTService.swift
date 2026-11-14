// M3.T01 skeleton → M3.T03 dictation (G-036; R-050, S-17, IS-9). The helper's speech-to-text entry points that
// `VoiceService` routes dictation and file transcription to. M3.T05 adds language routing (WhisperKit), M3.T06 files
// (`transcribeDiskBacked`); until then files answer `voice.unavailable`.
//
// One dictation (`DictationRun`): capture (microphone tap, or ScriptedVoice in DEBUG) → 16 kHz mono → level meter
// (`audioLevel`, 30 Hz) + Silero VAD (`vad-files`, voiced frames; speech onset) + the recogniser (`partialTranscript`
// while recording). Stop: ■ review / ↑ send-now → `finalTranscript` (empty when no frame was voiced or the
// recogniser heard only non-speech, R-050 AC3), then the audio is written to `recordingURL` if the app named one
// (not for an empty result), then `done`. × cancel → `done(cancelled)`, no final, no file.
// Models come through `VoiceModelProvider` (the scheduler's lease: budget, eviction, NFR-V10 warm), never a path of
// their own (D-11). Signposts (category `voice`): `dictation.speechOnset` → `dictation.firstPartial`,
// `dictation.stop` → `dictation.final`.
// M3 review P1-6: a dictation stops by itself after `maxDictation` (15 min, as ■: the transcript so far is the final),
// so a dictation whose app side went away cannot record forever. P2-2: a capture that fails to start closes the
// recogniser it already started. P2-1: a stop routed before the start reached this service is kept
// (`prepareDictation`).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import os

/// Sends voice items on a request's stream (the router batches and tags them with the request id).
public typealias VoiceEmit = @Sendable (_ items: [StreamItem]) -> Void

public protocol STTServing: Sendable {
    /// Opens dictation `start.requestID`: capture → partials → final on stop. Must end the stream (terminal
    /// engine event) only after `stopDictation` or on failure.
    func startDictation(_ start: DictationStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async
    /// ■ / ↑ / × for an open dictation.
    func stopDictation(_ stop: DictationStop) async
    /// The dictation `id` was routed (synchronous, before `startDictation`): a stop for it is kept from now on.
    func prepareDictation(_ id: UUID)
    /// Transcribes one file; emits `transcribeProgress` then `finalTranscript`, then `done`.
    func transcribe(_ request: TranscribeFile, models: VoiceModelSet, emit: @escaping VoiceEmit) async
}

/// A leased voice model: the object its materializer built, released when the run ends.
extension STTServing {
    public func prepareDictation(_ id: UUID) {}
}

public struct VoiceModelLease: Sendable {
    public let object: any Sendable
    public let release: @Sendable () async -> Void

    public init(object: any Sendable, release: @escaping @Sendable () async -> Void) {
        self.object = object
        self.release = release
    }
}

public protocol VoiceModelProvider: Sendable {
    /// Loads `slot` (if needed) through the one load authority and leases it for one run.
    func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease
}

/// Per-dictation latencies (seconds, monotonic) for the perf probes (`-Bench dictation`, V6 / V7).
public struct DictationTimings: Sendable, Equatable {
    public var speechOnset: Double?
    public var firstPartial: Double?
    public var stop: Double?
    public var final: Double?
    public var voicedFrames = 0
    public var levels = 0

    public var onsetToFirstPartial: Double? { firstPartial.flatMap { p in speechOnset.map { p - $0 } } }
    public var stopToFinal: Double? { final.flatMap { f in stop.map { f - $0 } } }
}

public final class STTService: STTServing {
    public typealias CaptureFactory = @Sendable (DictationStart) throws -> any AudioCaptureSource
    public typealias VADFactory = @Sendable (VoiceModelSet) -> (any VoiceActivityDetector)?
    public typealias BackendFactory = @Sendable (DictationStart, VoiceModelSet, any VoiceModelProvider) async throws
        -> (backend: any SpeechBackend, leases: [VoiceModelLease])

    private let provider: (any VoiceModelProvider)?
    private let capture: CaptureFactory
    private let vad: VADFactory
    private let backend: BackendFactory
    private let runs = RunTable()
    private let early = Mutex<[UUID: DictationStop.Mode?]>([:])
    /// The longest dictation (P1-6); then it stops as ■ (review).
    let maxDictation: Duration

    final class RunTable: Sendable {
        let m = Mutex<[UUID: DictationRun]>([:])
        func withLock<R>(_ body: (inout [UUID: DictationRun]) -> R) -> R { m.withLock { body(&$0) } }
    }
    private let timingTable = TimingTable()

    final class TimingTable: Sendable {
        let m = Mutex<[UUID: DictationTimings]>([:])
        subscript(id: UUID) -> DictationTimings? {
            get { m.withLock { $0[id] } }
            set { m.withLock { $0[id] = newValue } }
        }
    }

    /// `provider` nil = no voice service in this process: dictation answers `voice.unavailable`.
    public init(
        provider: (any VoiceModelProvider)? = nil, capture: @escaping CaptureFactory = STTService.defaultCapture,
        vad: @escaping VADFactory = STTService.sileroVAD, backend: @escaping BackendFactory = STTService.selected,
        maxDictation: Duration = .seconds(15 * 60)
    ) {
        self.maxDictation = maxDictation
        self.provider = provider
        self.capture = capture
        self.vad = vad
        self.backend = backend
    }

    public static let defaultCapture: CaptureFactory = { start in
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let script = start.scriptedInput { return try ScriptedVoice(script: URL(fileURLWithPath: script)) }
        #endif
        return MicCapture(deviceUID: start.deviceUID)
    }

    public static let sileroVAD: VADFactory = { models in
        guard let slot = models.slots[.vad] else { return EnergyVAD() }
        return (try? SileroVAD(directory: URL(fileURLWithPath: slot.path))) ?? EnergyVAD()
    }

    /// M3.T04: the session's backend (VoiceBackendSelector): Parakeet with the verified Voice pack, else Basic
    /// (SpeechAnalyzer). Decided here, once per dictation.
    public static let selected: BackendFactory = { start, models, provider in
        switch VoiceBackendSelector.stt(models) {
        case .full: return try await parakeet(start, models, provider)
        case .basic: return (SpeechAnalyzerBackend(), [])
        }
    }

    /// Parakeet (`stt`) + the streaming EOU model (`stt-eou`) for English partials when it is installed.
    public static let parakeet: BackendFactory = { start, models, provider in
        guard let stt = models.slots[.stt] else { throw AntiChatError.voice("unavailable", "the Voice pack is not installed") }
        var leases = [try await provider.lease(.stt, stt)]
        guard let model = leases[0].object as? ParakeetModel else { throw AntiChatError.voice("modelMismatch", "stt") }
        var eou: ParakeetEOUModel?
        if let slot = models.slots[.sttEOU], ParakeetBackend.usesEOU(locale: start.locale.map(Locale.init(identifier:))) {
            if let l = try? await provider.lease(.sttEOU, slot) {
                leases.append(l)
                eou = l.object as? ParakeetEOUModel
            }
        }
        // M3.T05: language routing — Parakeet for its 25 languages, WhisperKit (`stt-multi`, leased on demand) for the
        // others; `DictationStart.locale` carries Settings → Voice → Spoken language (nil = auto).
        let multi = models.slots[.sttMulti]
        let whisper: RoutedBackend.Lease = {
            guard let multi else { throw AntiChatError.voice("unavailable", "stt-multi (other languages) is not installed") }
            let l = try await provider.lease(.sttMulti, multi)
            guard let m = l.object as? WhisperKitModel else {
                await l.release()
                throw AntiChatError.voice("modelMismatch", "stt-multi")
            }
            return (m, l.release)
        }
        return (RoutedBackend(parakeet: ParakeetBackend(model: model, eou: eou), whisper: whisper, setting: start.locale,
                              whisperInstalled: multi != nil), leases)
    }

    /// The timings of a finished (or running) dictation (perf probes).
    public func timings(_ id: UUID) -> DictationTimings? { timingTable[id] }

    /// Whether dictation `id` is registered (a stop for it is honoured from now on). Tests wait on it.
    func isRegistered(_ id: UUID) -> Bool { runs.withLock { $0[id] != nil } }

    public func prepareDictation(_ id: UUID) {
        early.withLock { if $0[id] == nil { $0[id] = .some(nil) } }
    }

    public func startDictation(_ start: DictationStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        guard let provider else {
            _ = early.withLock { $0.removeValue(forKey: start.requestID) }
            return emit([.engine(.error(.voice("unavailable", "no voice service in this process")))])
        }
        let table = timingTable
        let run = DictationRun(start: start, emit: emit) { t in table[start.requestID] = t }
        // The run is registered and an early stop taken over in one step, so no stop falls between them.
        let earlyStop = runs.withLock { r -> DictationStop.Mode? in
            r[start.requestID] = run
            return early.withLock { $0.removeValue(forKey: start.requestID) } ?? nil
        }
        if earlyStop == .cancel {
            runs.withLock { _ = $0.removeValue(forKey: start.requestID) }
            return await run.fail(cancelled: true)
        }
        if let earlyStop { await run.stop(earlyStop) }  // kept as `pendingStop`, runs right after `begin`
        do {
            let (backend, leases) = try await backend(start, models, provider)
            try await run.begin(backend: backend, leases: leases, capture: capture(start), vad: vad(models))
        } catch {
            runs.withLock { _ = $0.removeValue(forKey: start.requestID) }
            await run.fail(error)
        }
        // P1-6 backstop: a dictation nobody stops ends at `maxDictation` (as ■).
        let limit = maxDictation
        let watchdog = Task { [runs] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            AppLog.log(.voice, .notice, "dictation: maximum length reached; stopping")
            let r = runs.withLock { $0.removeValue(forKey: start.requestID) }
            await (r ?? run).stop(.review)
        }
        defer { watchdog.cancel() }
        // The request lives until the dictation ends (the router closes a request whose body returns); a cancelled
        // request (`Cancel{requestID}`, client gone) cancels the dictation.
        await withTaskCancellationHandler {
            await run.ended()
        } onCancel: { [runs] in
            let r = runs.withLock { $0.removeValue(forKey: start.requestID) }
            Task { await (r ?? run).stop(.cancel) }
        }
        runs.withLock { _ = $0.removeValue(forKey: start.requestID) }
    }

    public func stopDictation(_ stop: DictationStop) async {
        let run = runs.withLock { r -> DictationRun? in
            if let run = r.removeValue(forKey: stop.requestID) { return run }
            // Routed but not started yet: the start takes the stop over.
            early.withLock { e in if e[stop.requestID] != nil { e[stop.requestID] = .some(stop.mode) } }
            return nil
        }
        await run?.stop(stop.mode)
    }

    /// M3.T06 (R-056): `FileTranscriber` with `stt` (+ `stt-multi` on demand) leased through the scheduler; emits
    /// `transcribeProgress` (0…100, monotonic), then `finalTranscript` (`[hh:mm:ss] text` lines) and `done`.
    public func transcribe(_ request: TranscribeFile, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        guard let provider else {
            return emit([.engine(.error(.voice("unavailable", "no voice service in this process")))])
        }
        guard let stt = models.slots[.stt] else {
            return emit([.engine(.error(.voice("unavailable", "the Voice pack is not installed")))])
        }
        do {
            let lease = try await provider.lease(.stt, stt)
            defer { Task { await lease.release() } }
            guard let parakeet = lease.object as? ParakeetModel else { throw AntiChatError.voice("modelMismatch", "stt") }
            var whisper: FileTranscriber.WhisperLease?
            if let slot = models.slots[.sttMulti] {
                whisper = {
                    let l = try await provider.lease(.sttMulti, slot)
                    guard let m = l.object as? WhisperKitModel else {
                        await l.release()
                        throw AntiChatError.voice("modelMismatch", "stt-multi")
                    }
                    return (m as any MultilingualRecognizer, l.release)
                }
            }
            let engines = FileTranscriber.Engines(
                parakeetFile: { url, p in try await parakeet.transcribeFile(url, progress: p) },
                parakeet: { try await parakeet.transcribe($0) }, whisper: whisper)
            let scratch = VoiceTemp.directory(VoiceTemp.transcribe)  // M3 review P2-6: per process, swept after a crash
            let final = try await FileTranscriber.transcribe(request, engines: engines, scratchDir: scratch) { p in
                emit([.voice(.transcribeProgress(p))])
            }
            emit([.voice(.finalTranscript(final)), .engine(.done(.stop))])
        } catch let e as AntiChatError {
            emit([.engine(.error(e))])
        } catch {
            emit([.engine(.error(.voice("transcribeFailed", String(describing: error))))])
        }
    }
}

// MARK: - One dictation

actor DictationRun {
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")
    let start: DictationStart
    let emit: VoiceEmit
    let report: @Sendable (DictationTimings) -> Void
    private var backend: (any SpeechBackend)?
    private var leases: [VoiceModelLease] = []
    private var capture: (any AudioCaptureSource)?
    private var partials: Task<Void, Never>?
    /// Capture-thread state (the tap callback never waits for the actor).
    private let live = LiveBox()
    private var stopped = false
    /// A stop that arrived while the models were still loading runs right after `begin`.
    private var pendingStop: DictationStop.Mode?
    private var begun = false
    private var finished = false
    private var terminalSent = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    final class LiveBox: Sendable {
        let m = Mutex(Live())
        func withLock<R>(_ body: (inout Live) -> R) -> R { m.withLock { body(&$0) } }
    }

    struct Live {
        var samples: [Float] = []
        var meter = LevelMeter()
        var vad: (any VoiceActivityDetector)?
        var vadPending: [Float] = []
        var timings = DictationTimings()
    }

    init(start: DictationStart, emit: @escaping VoiceEmit, report: @escaping @Sendable (DictationTimings) -> Void) {
        self.start = start
        self.emit = emit
        self.report = report
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    func begin(backend: any SpeechBackend, leases: [VoiceModelLease], capture: any AudioCaptureSource,
               vad: (any VoiceActivityDetector)?) async throws {
        self.backend = backend
        self.leases = leases
        self.capture = capture
        live.withLock { $0.vad = vad }
        let stream = try await backend.start(locale: start.locale.map(Locale.init(identifier:)))
        // P2-2: from here on a failure closes the recogniser (its polling tasks, the model it retains).
        do {
            try beginCapture(stream, backend: backend, capture: capture)
        } catch {
            partials?.cancel()
            partials = nil
            self.backend = nil
            await backend.cancel()
            throw error
        }
        emit([.voice(.voiceState(.listening))])
        begun = true
        if let mode = pendingStop { await stop(mode) }
    }

    private func beginCapture(_ stream: AsyncStream<STTEvent>, backend: any SpeechBackend,
                              capture: any AudioCaptureSource) throws {
        let emit = emit, live = live
        partials = Task {
            for await e in stream {
                guard case .partial(let text) = e else { continue }
                let first = live.withLock { l -> Bool in
                    guard l.timings.firstPartial == nil else { return false }
                    l.timings.firstPartial = Self.now()
                    return true
                }
                if first { Self.signposter.emitEvent("dictation.firstPartial") }
                emit([.voice(.partialTranscript(text))])
            }
        }
        try capture.start { [live, emit] samples in
            Self.ingest(samples, live: live, backend: backend, emit: emit)
        }
    }

    /// Capture thread: buffer, meter, VAD, recogniser.
    nonisolated static func ingest(_ samples: [Float], live: LiveBox, backend: any SpeechBackend, emit: VoiceEmit) {
        let levels = live.withLock { l -> [Float] in
            l.samples += samples
            let levels = l.meter.feed(samples)
            l.timings.levels += levels.count
            if let vad = l.vad {
                l.vadPending += samples
                let n = vad.frameSamples
                while l.vadPending.count >= n {
                    let frame = Array(l.vadPending.prefix(n))
                    l.vadPending.removeFirst(n)
                    if vad.isVoiced(frame) {
                        l.timings.voicedFrames += 1
                        if l.timings.speechOnset == nil {
                            l.timings.speechOnset = now()
                            signposter.emitEvent("dictation.speechOnset")
                        }
                    }
                }
            }
            return levels
        }
        backend.append(samples: samples)
        if !levels.isEmpty { emit(levels.map { .voice(.audioLevel($0)) }) }
    }

    func stop(_ mode: DictationStop.Mode) async {
        guard !stopped else { return }
        guard begun else {
            pendingStop = mode
            return
        }
        stopped = true
        capture?.stop()
        live.withLock { $0.timings.stop = Self.now() }
        let state = Self.signposter.beginInterval("dictation.stop")
        defer { Self.signposter.endInterval("dictation.stop", state) }
        guard let backend else { return await end([.engine(.done(.cancelled))]) }
        if mode == .cancel {
            await backend.cancel()
            partials?.cancel()
            return await end([.engine(.done(.cancelled))])
        }
        let (voiced, samples) = live.withLock { ($0.timings.voicedFrames > 0 || $0.vad == nil, $0.samples) }
        var final: FinalTranscript
        do {
            if voiced {
                final = try await backend.finish()
                if TranscriptText.isNonSpeech(final.text) { final.text = ""; final.segments = [] }
            } else {
                await backend.cancel()
                final = FinalTranscript(text: "", language: start.locale.map { String($0.prefix(2)) } ?? "en", engine: backend.engine)
            }
        } catch {
            return await end([.engine(.error(.voice("sttFailed", "\(error)")))])
        }
        await partials?.value
        live.withLock { $0.timings.final = Self.now() }
        Self.signposter.emitEvent("dictation.final")
        emit([.voice(.finalTranscript(final))])
        if !final.text.isEmpty, let url = start.recordingURL {
            do { try RecordingWriter.writeM4A(samples, to: url) } catch {
                AppLog.log(.engine, .error, "dictation recording \(url.lastPathComponent): \(error)")
            }
        }
        await end([.engine(.done(.stop))])
    }

    func fail(_ error: Error) async {
        stopped = true
        let e = (error as? AntiChatError) ?? .voice("sttFailed", "\(error)")
        await end([.engine(.error(e))])
    }

    /// × before the dictation started: nothing opened, nothing to report but the cancel.
    func fail(cancelled: Bool) async {
        stopped = true
        await end([.engine(.done(.cancelled))])
    }

    private func end(_ items: [StreamItem]) async {
        guard !finished else { return }
        finished = true
        capture?.stop()
        // The terminal event is the stream's last item: a partial the recogniser yielded just before the stop / cancel
        // may still be on its way through the partials task (a cancel never awaited it, so under load a
        // `partialTranscript` landed after `done(cancelled)`). End that task and wait for it first.
        partials?.cancel()
        await partials?.value
        partials = nil
        report(live.withLock { $0.timings })
        for l in leases { await l.release() }
        leases = []
        emit(items)
        terminalSent = true
        for w in waiters { w.resume() }
        waiters = []
    }

    /// Returns once the dictation has emitted its terminal event (not merely begun ending: `end` suspends between
    /// the two, and a request that returned in that gap closed before its terminal event).
    func ended() async {
        guard !terminalSent else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
