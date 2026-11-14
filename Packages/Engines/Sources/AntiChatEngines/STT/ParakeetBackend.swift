// M3.T03 step 2 (P-media-02; R-050): Parakeet TDT (`stt`, Parakeet Ultra) on the ANE through FluidAudio 0.18.0.
// Loader: `AsrModels.loadLocal(from:version:configuration:encoderPrecision:encoderComputeUnits:)`
//   FluidInference/FluidAudio@e15287985625dbf544a343df679436789ffb03fb:Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:349
//   (the resolved 0.18.0 revision) — this exact directory, no repository resolution, no download; ModelHub.offlineMode
//   is set at helper start (VoiceEnvironment.lockDown, D-11).
// Streaming English partials: `StreamingEouAsrManager.loadModels(from:)` on `stt-eou/160ms`
//   …@e152879:Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift:330 (partial callback :649).
// Partials: English with `stt-eou` registered (T1+ sets) → the EOU model's running transcript every 160 ms chunk;
// its confirmed EOU token is a separate STTEvent for M3.T09's second end-of-turn signal. Otherwise `PartialWindow`
// re-runs Parakeet every 500 ms on the open part. Final: while recording, Parakeet commits
// the audio up to each pause (≥ 6 s, `PartialWindow.nextCommit`); at stop it recognises only the tail since the last
// commit and joins the texts (NFR-V7: the stop → final pass stays short for a 30 s monologue).
// Compute placement: Core ML defaults of FluidAudio (ANE + CPU), never the GPU (K-NEW-ENG-10).
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import AntiChatEngineProtocol
import FluidAudio
import Foundation
import Synchronization

/// The resident Parakeet model (materialized by `VoiceModelResidency` for key `stt`).
public actor ParakeetModel {
    private let manager: AsrManager

    public static func load(directory: URL) async throws -> ParakeetModel {
        let models = try AsrModels.loadLocal(from: directory, version: .ultra)
        return ParakeetModel(manager: AsrManager(config: .default, models: models))
    }

    private init(manager: AsrManager) { self.manager = manager }

    public struct Result: Sendable {
        public var text: String
        public var segments: [TranscriptSegment]
        /// FluidAudio's mean token confidence (0…1; AT-284: low on speech in a language Parakeet does not know).
        public var confidence: Float = 1
    }

    /// 16 kHz mono samples → text (+ word segments from the token timings). Parakeet needs ≥ 1 s: shorter input is
    /// padded with trailing silence.
    public func transcribe(_ samples: [Float]) async throws -> Result {
        var x = samples
        if x.count < 16_000 { x += [Float](repeating: 0, count: 16_000 - x.count) }
        var state = TdtDecoderState.make()
        let r = try await manager.transcribe(x, decoderState: &state)
        return Result(text: r.text.trimmingCharacters(in: .whitespacesAndNewlines), segments: Self.segments(r.tokenTimings ?? []),
                      confidence: r.confidence)
    }

    /// M3.T06: a 16 kHz file through FluidAudio's disk-backed chunked path (`transcribeDiskBacked`, memory-mapped);
    /// `progress` 0…1 from its progress stream (files > 15 s; shorter ones report only the end).
    public func transcribeFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let stream = await manager.transcriptionProgressStream
        let watcher = Task {
            do { for try await p in stream { progress(p) } } catch {}
        }
        defer { watcher.cancel() }
        var state = TdtDecoderState.make()
        let r = try await manager.transcribeDiskBacked(url, decoderState: &state)
        progress(1)
        return Result(text: r.text.trimmingCharacters(in: .whitespacesAndNewlines), segments: Self.segments(r.tokenTimings ?? []),
                      confidence: r.confidence)
    }

    /// SentencePiece pieces → words (a piece starting with "▁" opens a word).
    static func segments(_ timings: [TokenTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for t in timings {
            let opens = t.token.hasPrefix("▁") || t.token.hasPrefix(" ") || out.isEmpty
            let piece = t.token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if opens {
                out.append(TranscriptSegment(start: t.startTime, end: t.endTime, text: piece))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = t.endTime
            }
        }
        return out.filter { !$0.text.isEmpty }
    }
}

/// The resident streaming EOU model (key `stt-eou`), used for live English partials only.
public actor ParakeetEOUModel {
    private let manager: StreamingEouAsrManager

    public static func load(directory: URL) async throws -> ParakeetEOUModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine  // never the GPU (chat decode, K-NEW-ENG-10)
        let m = StreamingEouAsrManager(configuration: cfg, chunkSize: .ms160)
        // The catalog slot holds the 160 ms set in its own folder.
        let sub = directory.appendingPathComponent("160ms")
        try await m.loadModels(from: FileManager.default.fileExists(atPath: sub.path) ? sub : directory)
        return ParakeetEOUModel(manager: m)
    }

    private init(manager: StreamingEouAsrManager) { self.manager = manager }

    func begin(
        _ onPartial: @escaping @Sendable (String) -> Void,
        onEOU: @escaping @Sendable () -> Void
    ) async {
        await manager.reset()
        await manager.setPartialCallback(onPartial)
        await manager.setEouCallback { _ in onEOU() }
    }

    func feed(_ samples: [Float]) async throws {
        guard let b = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.pcm, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        _ = try await manager.process(audioBuffer: b)
    }

    func end() async {
        await manager.setPartialCallback { _ in }
        await manager.setEouCallback { _ in }
        await manager.reset()
    }
}

public final class ParakeetBackend: SpeechBackend, @unchecked Sendable {
    /// Parakeet v3 / Ultra's languages (FluidAudio README, model card): 25 European languages.
    public static let languageCodes: Set<String> = SpokenLanguages.parakeet

    public let engine: STTEngineID = .parakeet
    public let supportsPartials = true
    public var languages: Set<String> { Self.languageCodes }

    private let model: ParakeetModel
    private let eou: ParakeetEOUModel?
    private let state = Mutex(State())
    // Set in start, cleared in finish / cancel; one utterance at a time (the dictation run serialises them).
    private var partialTask: Task<Void, Never>?
    private var eouTask: Task<Void, Never>?
    private var language = "en"

    struct State {
        var samples: [Float] = []
        var window = PartialWindow()
        var segments: [TranscriptSegment] = []
        /// The lowest confidence over the committed passes (AT-284 auto routing).
        var confidence: Float = 1
        var usesEOU = false
        var eouPending: [Float] = []
        var eouQueue: [[Float]] = []
        var lastPartial = ""
        var open = false
        var continuation: AsyncStream<STTEvent>.Continuation?
    }

    public init(model: ParakeetModel, eou: ParakeetEOUModel? = nil) {
        self.model = model
        self.eou = eou
    }

    /// The streaming EOU model is English-only.
    static func usesEOU(locale: Locale?) -> Bool { (locale?.language.languageCode?.identifier ?? "en") == "en" }

    public func start(locale: Locale?) async throws -> AsyncStream<STTEvent> {
        language = locale?.language.languageCode?.identifier ?? "en"
        let (stream, cont) = AsyncStream<STTEvent>.makeStream()
        let eouOn = eou != nil && Self.usesEOU(locale: locale)
        state.withLock {
            $0 = State()
            $0.open = true
            $0.usesEOU = eouOn
            $0.continuation = cont
        }
        if let eou, eouOn {
            await eou.begin({ [weak self] text in self?.publish(text) }, onEOU: { [weak self] in self?.publishEOU() })
            eouTask = Task { [weak self] in await self?.runEOU(eou) }
        }
        partialTask = Task { [weak self] in await self?.runWindow(partials: !eouOn) }
        return stream
    }

    public func append(samples: [Float]) {
        state.withLock { s in
            guard s.open else { return }
            s.samples += samples
            s.window.feed(samples)
            guard s.usesEOU else { return }
            s.eouPending += samples
            let chunk = 2_560  // 160 ms
            while s.eouPending.count >= chunk {
                s.eouQueue.append(Array(s.eouPending.prefix(chunk)))
                s.eouPending.removeFirst(chunk)
            }
        }
    }

    public func finish() async throws -> FinalTranscript {
        state.withLock { $0.open = false }
        await stopPartials()
        return try await transcribeAppended()
    }

    /// The utterance so far through the same path as `finish` (committed window text + the tail), stream left open.
    public func provisional() async throws -> FinalTranscript? {
        guard state.withLock({ $0.open }) else { return nil }
        return try await transcribeAppended()
    }

    private func transcribeAppended() async throws -> FinalTranscript {
        let (tail, offset, committed, segments, conf) = state.withLock { s -> ([Float], Int, String, [TranscriptSegment], Float) in
            let c = s.window.committedSamples
            return (Array(s.samples[min(c, s.samples.count)...]), c, s.window.committedText, s.segments, s.confidence)
        }
        var text = committed, segs = segments, confidence = conf
        if tail.count >= 1_600 || committed.isEmpty {  // ≥ 0.1 s left (or nothing committed yet)
            let r = try await model.transcribe(tail)
            text = PartialWindow.join(committed, r.text)
            segs += Self.shift(r.segments, by: offset)
            confidence = min(confidence, r.confidence)
        }
        return FinalTranscript(text: text, language: language, engine: .parakeet, segments: segs, confidence: confidence)
    }

    static func shift(_ segments: [TranscriptSegment], by samples: Int) -> [TranscriptSegment] {
        let dt = Double(samples) / 16_000
        return segments.map { TranscriptSegment(start: $0.start + dt, end: $0.end + dt, text: $0.text) }
    }

    public func cancel() async {
        state.withLock { $0.open = false }
        await stopPartials()
    }

    private func stopPartials() async {
        partialTask?.cancel()
        eouTask?.cancel()
        await partialTask?.value
        await eouTask?.value
        partialTask = nil
        eouTask = nil
        if let eou { await eou.end() }
        state.withLock { s in
            s.continuation?.finish()
            s.continuation = nil
        }
    }

    private func publish(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.withLock { s in
            guard s.open, t != s.lastPartial, !t.isEmpty else { return }
            s.lastPartial = t
            s.continuation?.yield(.partial(t))
        }
    }

    private func publishEOU() {
        state.withLock { s in
            guard s.open else { return }
            s.continuation?.yield(.endOfUtterance)
        }
    }

    /// Commits at pauses (always) and, without a streaming model, partials every 500 ms. A commit that finishes
    /// after stop still lands (finish waits for this task), so the tail never repeats committed audio.
    private func runWindow(partials: Bool) async {
        var lastTick = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            var job: (PartialWindow.Job, [Float])?
            let due = ContinuousClock.now - lastTick >= PartialWindow.interval
            state.withLock { s in
                let count = s.samples.count
                if let c = s.window.nextCommit(count: count) {
                    job = (.commit(c), Array(s.samples[c]))
                } else if partials, due, let r = s.window.nextPartial(count: count) {
                    job = (.partial(r), Array(s.samples[r]))
                }
            }
            guard let (j, audio) = job else { continue }
            if case .partial = j { lastTick = .now }
            guard let r = try? await model.transcribe(audio) else { continue }
            switch j {
            case .commit(let range):
                state.withLock { s in
                    s.window.committed(range, text: r.text)
                    s.segments += Self.shift(r.segments, by: range.lowerBound)
                    s.confidence = min(s.confidence, r.confidence)
                }
                if partials { publish(state.withLock { $0.window.committedText }) }
            case .partial: publish(state.withLock { $0.window.compose(r.text) })
            }
        }
    }

    private func runEOU(_ eou: ParakeetEOUModel) async {
        while !Task.isCancelled {
            let chunks = state.withLock { s -> [[Float]] in
                defer { s.eouQueue.removeAll() }
                return s.eouQueue
            }
            if chunks.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            for c in chunks where !Task.isCancelled { try? await eou.feed(c) }
        }
    }
}
