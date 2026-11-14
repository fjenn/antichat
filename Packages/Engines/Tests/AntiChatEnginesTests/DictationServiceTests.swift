// M3.T03 (R-050; AT-050 AC3/AC4 helper legs, NFR-V6/V7 plumbing): the dictation pipeline in the helper without
// real models — ScriptedVoice capture, the 500 ms partial window, the level meter, the silence-only rule, the
// recording file, cancel, and a stop that arrives while the models still load. Real Parakeet: ParakeetBackendTests.
//   make test-unit FILTER=DictationServiceTests
import AntiChatEngineProtocol
import AntiChatFoundation
@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

enum VoiceTestAudio {
    static let fixturesRoot: URL? = {
        if let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !f.isEmpty { return URL(fileURLWithPath: f) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let f = repo.appendingPathComponent("fixtures")
        return FileManager.default.fileExists(atPath: f.appendingPathComponent("voice/scripts").path) ? f : nil
    }()

    static func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-\(tag)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A 16 kHz mono WAV: `seconds` of a 220 Hz tone at `dBFS` (−20 = "speech" for the energy gate).
    static func tone(_ url: URL, seconds: Double, dBFS: Double = -20) throws {
        let n = Int(seconds * 16_000), a = Float(pow(10, dBFS / 20) * 1.414)
        try writeWAV((0..<n).map { a * sin(2 * .pi * 220 * Float($0) / 16_000) }, sampleRate: 16_000, to: url)
    }
}

struct PartialWindowTests {
    static func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.1 * sin(Float($0) * 0.08) } }
    static func quiet(_ seconds: Double) -> [Float] { [Float](repeating: 1e-4, count: Int(seconds * 16_000)) }

    @Test func partialsRunOnNewAudioOnly() {
        var w = PartialWindow()
        #expect(w.next(count: 1_000) == nil, "under 0.25 s: nothing to recognise yet")
        #expect(w.next(count: 8_000) == .partial(0..<8_000))
        #expect(w.next(count: 8_000) == nil, "no new audio, no new run")
        #expect(w.next(count: 16_000) == .partial(0..<16_000))
    }

    @Test func commitsAtAPauseAfterSixSeconds() {
        var w = PartialWindow()
        let speech = Self.tone(3) + Self.quiet(0.8) + Self.tone(4) + Self.quiet(0.8) + Self.tone(2)
        w.feed(speech)
        // The first pause (at 3 s) is before the 6 s minimum; the second (7.8–8.6 s) is the cut, at its middle.
        guard let c = w.nextCommit(count: speech.count) else { Issue.record("expected a commit"); return }
        #expect(c.lowerBound == 0)
        let cut = Double(c.upperBound) / 16_000
        #expect(cut > 7.8 && cut < 8.6, "\(cut)")
        w.committed(c, text: "first part")
        #expect(w.nextCommit(count: speech.count) == nil, "the open part is under 6 s now")
        #expect(w.next(count: speech.count) == .partial(c.upperBound..<speech.count))
        #expect(w.compose("and the rest") == "first part and the rest")
        w.committed(0..<10, text: "stale")  // a commit for an old range is ignored
        #expect(w.committedText == "first part")
    }

    @Test func withoutAPauseTheOpenPartIsCutAt30s() {
        var w = PartialWindow()
        w.feed(Self.tone(31))
        #expect(w.nextCommit(count: 31 * 16_000) == 0..<(30 * 16_000), "no recognition run covers more than 30 s")
    }
}

struct ScriptedVoiceTests {
    @Test func timelinePlacesItemsAtTheirStartWithGain() throws {
        let dir = VoiceTestAudio.tempDir("sv")
        try VoiceTestAudio.tone(dir.appendingPathComponent("a.wav"), seconds: 0.5)
        let script = dir.appendingPathComponent("s.jsonl")
        try """
            {"t_ms": 250, "wav": "a.wav"}
            {"t_ms": 0, "wav": "a.wav", "gain_db": -6}
            """.write(to: script, atomically: true, encoding: .utf8)
        let sv = try ScriptedVoice(script: script)
        #expect(sv.items.count == 2)
        // 0.25 s quiet, 0.5 s tone, then the second item right after (its t_ms is already past), 6 dB down.
        #expect(abs(sv.duration - 1.25) < 0.01)
        #expect(rmsDBFS(Array(sv.timeline[0..<4_000])) < -85)
        let first = rmsDBFS(Array(sv.timeline[4_000..<12_000])), second = rmsDBFS(Array(sv.timeline[12_000..<20_000]))
        #expect(abs(first - -20) < 0.5)
        #expect(abs((first - second) - 6) < 0.5)
        // After the script: quiet, never digital zero.
        let tail = sv.samples(20_000..<20_320)
        #expect(tail.count == 320 && rmsDBFS(tail) < -85 && tail.contains { $0 != 0 })
    }

    @Test func deliversTwentyMillisecondFramesAtPaceUntilStopped() async throws {
        let dir = VoiceTestAudio.tempDir("sv-pace")
        try VoiceTestAudio.tone(dir.appendingPathComponent("a.wav"), seconds: 1)
        let script = dir.appendingPathComponent("s.jsonl")
        try #"{"t_ms": 0, "wav": "a.wav"}"#.write(to: script, atomically: true, encoding: .utf8)
        let sv = try ScriptedVoice(script: script, speed: 4)
        let got = Mutex<[Int]>([])
        let t0 = ContinuousClock.now
        try sv.start { s in got.withLock { $0.append(s.count) } }
        // Until > 1 s of audio (past the 1 s script) has arrived, bounded at 15 s; pacing is checked against the wall.
        let deadline = ContinuousClock.now + .seconds(15)
        while got.withLock({ $0.reduce(0, +) }) <= 16_320, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        sv.stop()
        let elapsed = ContinuousClock.now - t0
        let frames = got.withLock { $0 }
        let after = frames.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(got.withLock { $0.count } == after, "no frame after stop")
        #expect(frames.allSatisfy { $0 == 320 })
        let seconds = Double(frames.reduce(0, +)) / 16_000
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds <= wall * 4 + 0.05, "never ahead of the pace")
        #expect(seconds >= 1.0, "keeps delivering (quiet) past the end of the script")
    }

    /// Every committed dictation script resolves its WAVs (fixtures repo).
    @Test(.enabled(if: VoiceTestAudio.fixturesRoot != nil)) func fixtureScriptsResolve() throws {
        let dir = VoiceTestAudio.fixturesRoot!.appendingPathComponent("voice/scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("dictation-") && $0.hasSuffix(".jsonl") }
        #expect(Set(names).isSuperset(of: ["anatomy", "stop-review", "send-now", "cancel", "silence", "recordings", "incognito"]
            .map { "dictation-\($0).jsonl" }))
        for n in names { #expect(try ScriptedVoice(script: dir.appendingPathComponent(n)).duration > 0.5, "\(n)") }
    }
}

/// A recogniser that reports how much audio it got (`heard <n>`); partials every append past 0.5 s of audio.
final class FakeBackend: SpeechBackend, @unchecked Sendable {
    let engine: STTEngineID = .parakeet
    let supportsPartials = true
    let languages: Set<String> = ["en"]
    let finalText: String
    let calls = Mutex<[String]>([])
    let count = Mutex(0)
    private var cont: AsyncStream<STTEvent>.Continuation?

    init(finalText: String = "hello world") { self.finalText = finalText }

    func start(locale: Locale?) async throws -> AsyncStream<STTEvent> {
        calls.withLock { $0.append("start") }
        let (s, c) = AsyncStream<STTEvent>.makeStream()
        cont = c
        return s
    }

    func append(samples: [Float]) {
        let n = count.withLock { $0 += samples.count; return $0 }
        if n % 8_000 < samples.count, n >= 8_000 { cont?.yield(.partial("heard \(n / 8_000)")) }
    }

    func finish() async throws -> FinalTranscript {
        calls.withLock { $0.append("finish") }
        cont?.finish()
        return FinalTranscript(text: finalText, language: "en", engine: .parakeet)
    }

    func cancel() async {
        calls.withLock { $0.append("cancel") }
        cont?.finish()
    }

    /// The voice session's pause transcript: the final text, utterance left open.
    func provisional() async throws -> FinalTranscript? {
        FinalTranscript(text: finalText, language: "en", engine: .parakeet)
    }
}

struct FakeProvider: VoiceModelProvider {
    func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
        VoiceModelLease(object: slot.key) {}
    }
}

final class VoiceSink: @unchecked Sendable {
    let m = Mutex<[StreamItem]>([])
    var items: [StreamItem] { m.withLock { $0 } }
    var emit: VoiceEmit { { [self] i in m.withLock { $0 += i } } }
    var voice: [VoiceEvent] { items.compactMap { if case .voice(let v) = $0 { v } else { nil } } }
    var partials: [String] { voice.compactMap { if case .partialTranscript(let t) = $0 { t } else { nil } } }
    var finals: [FinalTranscript] { voice.compactMap { if case .finalTranscript(let f) = $0 { f } else { nil } } }
    var levels: [Float] { voice.compactMap { if case .audioLevel(let l) = $0 { l } else { nil } } }
    var terminal: EngineEvent? { items.last.flatMap { if case .engine(let e) = $0, $0.isTerminal { e } else { nil } } }

    func waitTerminal(_ seconds: Double = 20) async {
        await waitFor(seconds) { terminal != nil }
    }

    /// A bounded wait on a real condition (the tests' former fixed sleeps flaked on a loaded host).
    func waitFor(_ seconds: Double = 15, _ cond: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !cond(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The dictation is capturing: `frames` level ticks (≈ 32 ms of audio each) have arrived.
    func waitCapturing(_ frames: Int = 8) async { await waitFor { levels.count >= frames } }
}

struct DictationServiceTests {
    static let models = VoiceModelSet(slots: [.stt: ModelSlot(engine: .coreml, key: "stt", path: "/x"),
                                              .vad: ModelSlot(engine: .coreml, key: "vad-files", path: "/x")])

    static func service(_ backend: FakeBackend, speed: Double = 4, vad: (any VoiceActivityDetector)? = EnergyVAD(),
                        delay: Duration = .zero) -> STTService {
        STTService(
            provider: FakeProvider(),
            capture: { start in try ScriptedVoice(script: URL(fileURLWithPath: start.scriptedInput!), speed: speed) },
            vad: { _ in vad },
            backend: { _, _, _ in
                if delay > .zero { try await Task.sleep(for: delay) }
                return (backend, [])
            })
    }

    static func script(_ toneSeconds: Double, dBFS: Double = -20) throws -> URL {
        let dir = VoiceTestAudio.tempDir("dict")
        try VoiceTestAudio.tone(dir.appendingPathComponent("u.wav"), seconds: toneSeconds, dBFS: dBFS)
        let s = dir.appendingPathComponent("s.jsonl")
        try #"{"t_ms": 200, "wav": "u.wav"}"#.write(to: s, atomically: true, encoding: .utf8)
        return s
    }

    @Test func reviewStreamsLevelsPartialsThenFinalThenWritesTheRecording() async throws {
        let backend = FakeBackend()
        let svc = Self.service(backend)
        let sink = VoiceSink()
        let rec = VoiceTestAudio.tempDir("rec").appendingPathComponent("d.m4a")
        let start = DictationStart(recordingURL: rec, scriptedInput: try Self.script(30).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        // Stop once the recogniser holds > 2.1 s of audio (the recording holds at least that much).
        await sink.waitFor { backend.count.withLock { $0 } >= 33_600 }
        await svc.stopDictation(DictationStop(requestID: start.requestID, mode: .review))
        await sink.waitTerminal()
        await run.value  // the request ends with the dictation
        #expect(sink.terminal == .done(.stop))
        #expect(sink.finals.map(\.text) == ["hello world"])
        #expect(!sink.partials.isEmpty)
        #expect(sink.levels.count >= 30, "≈ 30 levels per second of audio")
        // The level follows the audio: the quiet lead-in (≈ −95 dBFS) and the −20 dBFS tone are both there (no count of
        // distinct values — how many transition ticks land depends on the capture pace under load).
        #expect(sink.levels.contains { $0 < -80 } && sink.levels.contains { abs($0 - -20) < 2 }, "the level follows the audio")
        // Order: partials before the final, the final before done.
        let kinds = sink.voice.map { e -> String in
            switch e { case .partialTranscript: "p"; case .finalTranscript: "f"; default: "" }
        }.filter { !$0.isEmpty }
        #expect(kinds.last == "f" && kinds.dropLast().allSatisfy { $0 == "p" })
        #expect(backend.calls.withLock { $0 } == ["start", "finish"])
        let file = try AVAudioFile(forReading: rec)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(Double(file.length) / 16_000 > 2, "the recording holds the whole dictation")
        let t = try #require(svc.timings(start.requestID))
        #expect(t.speechOnset != nil && t.firstPartial != nil && t.stopToFinal != nil)
    }

    @Test func silenceOnlyGivesAnEmptyFinalWithoutRecogniserOrFile() async throws {
        let backend = FakeBackend()
        let svc = Self.service(backend)
        let sink = VoiceSink()
        let rec = VoiceTestAudio.tempDir("rec").appendingPathComponent("d.m4a")
        let start = DictationStart(recordingURL: rec, scriptedInput: try Self.script(1, dBFS: -65).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        await sink.waitCapturing(25)  // ≈ 0.8 s of (silent) audio
        await svc.stopDictation(DictationStop(requestID: start.requestID, mode: .review))
        await sink.waitTerminal()
        await run.value  // the request ends with the dictation
        #expect(sink.finals.map(\.text) == [""], "R-050 AC3: empty, no error")
        #expect(sink.terminal == .done(.stop))
        #expect(backend.calls.withLock { $0 } == ["start", "cancel"], "no recogniser pass on silence")
        #expect(!FileManager.default.fileExists(atPath: rec.path))
    }

    @Test func nonSpeechTranscriptIsEmpty() async throws {
        let backend = FakeBackend(finalText: "[noise] …")
        let svc = Self.service(backend)
        let sink = VoiceSink()
        let start = DictationStart(scriptedInput: try Self.script(30).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        await sink.waitFor { backend.count.withLock { $0 } > 0 }  // the recogniser is hearing the utterance
        await svc.stopDictation(DictationStop(requestID: start.requestID, mode: .sendNow))
        await sink.waitTerminal()
        await run.value  // the request ends with the dictation
        #expect(sink.finals.map(\.text) == [""])
        #expect(TranscriptText.isNonSpeech("<unk> (cough)") && !TranscriptText.isNonSpeech("Hi."))
    }

    @Test func cancelEndsWithoutFinalOrFile() async throws {
        let backend = FakeBackend()
        let svc = Self.service(backend)
        let sink = VoiceSink()
        let rec = VoiceTestAudio.tempDir("rec").appendingPathComponent("d.m4a")
        // 30 s of input: on a loaded host the 2 s script could end on its own before the cancel arrived.
        let start = DictationStart(recordingURL: rec, scriptedInput: try Self.script(30).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        await sink.waitFor { backend.count.withLock { $0 } > 0 }  // recording and recognising
        await svc.stopDictation(DictationStop(requestID: start.requestID, mode: .cancel))
        await sink.waitTerminal()
        await run.value  // the request ends with the dictation
        #expect(sink.terminal == .done(.cancelled))
        #expect(sink.finals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rec.path))
    }

    @Test func aStopWhileTheModelsLoadStillEndsTheDictation() async throws {
        let backend = FakeBackend()
        let svc = Self.service(backend, delay: .milliseconds(300))
        let sink = VoiceSink()
        let start = DictationStart(scriptedInput: try Self.script(30).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        await sink.waitFor { svc.isRegistered(start.requestID) }  // registered; its models are still loading (300 ms)
        await svc.stopDictation(DictationStop(requestID: start.requestID, mode: .cancel))
        await run.value
        await sink.waitTerminal()
        #expect(sink.terminal == .done(.cancelled))
    }

    // Every case that stops, cancels or sends records 30 s of scripted input: a short script could end on its own
    // before the stop / cancel on a loaded host (round-13 merge gate, load ~40). It still failed at load ~55–80 after
    // that (22 s: `waitTerminal` timed out because the stream's last item was not terminal): a partial the
    // recogniser had already handed to the partials task was emitted after `done(cancelled)`; the run now ends that
    // task before its terminal event (DictationRun.end).
    @Test func cancellingTheRequestCancelsTheDictation() async throws {
        let backend = FakeBackend()
        let svc = Self.service(backend)
        let sink = VoiceSink()
        let start = DictationStart(scriptedInput: try Self.script(30).path)
        let run = Task { await svc.startDictation(start, models: Self.models, emit: sink.emit) }
        await sink.waitFor { backend.count.withLock { $0 } > 0 }  // the dictation is running
        run.cancel()  // the router's Cancel{requestID} / client gone
        await run.value
        await sink.waitTerminal()
        #expect(sink.terminal == .done(.cancelled) && sink.finals.isEmpty)
    }

    @Test func withoutAVoiceServiceDictationIsUnavailable() async {
        let svc = STTService()
        let sink = VoiceSink()
        await svc.startDictation(DictationStart(), models: VoiceModelSet(slots: [:]), emit: sink.emit)
        guard case .error(let e) = sink.terminal else { Issue.record("expected an error"); return }
        #expect(e.fullCode == "voice.unavailable")
    }

    @Test func levelMeterTicksAt30Hz() {
        var m = LevelMeter()
        let levels = m.feed([Float](repeating: 0.1, count: 16_000))
        #expect(levels.count == 30)
        #expect(levels.allSatisfy { abs($0 - -20) < 0.1 })
    }
}
