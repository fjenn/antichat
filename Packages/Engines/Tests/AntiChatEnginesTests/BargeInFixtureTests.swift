// M3.T10 step 7 / AT-282, AT-NFR-V3 (`@realModels`, mode inject [IN-PIPELINE]): a real VoiceSession — Silero (Core ML),
// smart-turn, Parakeet (+ EOU), Kokoro — on `fixtures/audio/barge-in/` (12 items × 3 rooms). The assistant speaks the
// item's `tts_text` (the reply streamed word by word like a chat turn) into a silent output clock; when its first chunk
// starts, the item's `-user` stem (the user speech, convolved with the room, starting `onset_ms` after the TTS start)
// is fed into the capture tap in real time, VPIO bypassed (in-pipeline injection carries no echo; echo robustness is
// AT-280's job; the `-mic` stems are diagnostics only).
// Per item: the reply stops (`ttsStopped(.bargeIn)`), the stored text (`spokenSpan`) is checked against the reply words
// whose audio had started at the stop (|Δ words| ≤ 1, R-282 AC2), the interrupting utterance gets its own final
// transcript (R-052 AC3), and onset → TTS silent / → cancel are timed (NFR-V3).
// "Heard" reference (A-M9-T05-AT282b): the acoustic onset of every reply word in the TTS audio the sink received,
// by forced alignment of the reply text (`tools/voice/word-onsets.py`, Montreal Forced Aligner; never Kokoro's own
// durations), counted when the onset precedes the played sample. Needs the MFA environment (see that file).
//   ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=$PWD/fixtures gpu-run.sh timing -- swift test --filter BargeInFixtureTests
//   → build/at/AT-282/spans.json, build/at/AT-282/v3.json (this checkout's build/at, whatever ANTICHAT_FIXTURES says)
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation
import SpeechSwiftVendored
import Synchronization
import Testing
@testable import AntiChatEngines

/// A silent clock that keeps what it was given (the reference for "what was heard").
final class RecordingSink: VoiceOutputSink, @unchecked Sendable {
    let inner = ClockedSilentSink()
    let audio = Mutex<[Float]>([])
    func prepare(sampleRate: Int) throws { try inner.prepare(sampleRate: sampleRate) }
    func schedule(_ samples: [Float]) {
        audio.withLock { $0 += samples }
        inner.schedule(samples)
    }
    var playedSamples: Int { inner.playedSamples }
    var scheduledSamples: Int { inner.scheduledSamples }
    var sampleRate: Int { inner.sampleRate }
    func pause() { inner.pause() }
    func resume() { inner.resume() }
    func flush() { inner.flush() }
    func setMuted(_ muted: Bool) {}
    func take() -> [Float] { audio.withLock { a in defer { a = [] }; return a } }
}

/// Real-time capture: −90 dBFS dither in 32 ms frames, with injected audio mixed in from the moment it is queued.
final class RealtimeInjector: AudioCaptureSource, @unchecked Sendable {
    private let state = Mutex<(cb: (@Sendable ([Float]) -> Void)?, queue: [Float], startNs: UInt64?)>((nil, [], nil))
    private var timer: DispatchSourceTimer?

    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        state.withLock { $0.cb = onSamples }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "inject", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(32), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        state.withLock { $0.cb = nil }
    }

    /// Queues `samples` to play from the next frame on; returns the host time of their first sample.
    @discardableResult
    func inject(_ samples: [Float]) -> UInt64 {
        state.withLock { s in
            s.queue = samples
            let now = VoiceAudioSignposts.now()
            s.startNs = now
            return now
        }
    }

    var idle: Bool { state.withLock { $0.queue.isEmpty } }

    private func tick() {
        let (cb, frame) = state.withLock { s -> ((@Sendable ([Float]) -> Void)?, [Float]) in
            var f = (0..<512).map { _ in Float.random(in: -3e-5...3e-5) }
            let n = min(512, s.queue.count)
            for i in 0..<n { f[i] += s.queue[i] }
            if n > 0 { s.queue.removeFirst(n) }
            return (s.cb, f)
        }
        cb?(frame)
    }
}

/// Models loaded once, straight from the dev model store (no scheduler: this is the session's own test).
actor DirectVoiceModels: VoiceModelProvider {
    static let root = ParakeetBackendTests.models
    private var cache: [String: any Sendable] = [:]

    func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
        if let o = cache[slot.key] { return VoiceModelLease(object: o) {} }
        let dir = URL(fileURLWithPath: slot.path)
        let o: any Sendable
        switch role {
        case .stt: o = try await ParakeetModel.load(directory: dir)
        case .sttEOU: o = try await ParakeetEOUModel.load(directory: dir)
        case .turn: o = try SmartTurnLoader.load(turnDirectory: dir)
        case .tts: o = try await KokoroTTS.load(slotDirectory: dir)
        default: throw AntiChatError.voice("unavailable", slot.key)
        }
        cache[slot.key] = o
        return VoiceModelLease(object: o) {}
    }

    static func slot(_ key: String, _ dir: String) -> ModelSlot {
        ModelSlot(engine: .coreml, key: key, path: root.appendingPathComponent(dir).path, footprintBytes: 1)
    }

    static let set = VoiceModelSet(slots: [
        .stt: slot("stt", "stt"), .sttEOU: slot("stt-eou", "stt-eou"), .vad: slot("vad-files", "vad-files"),
        .turn: ModelSlot(engine: .coreml, key: "turn-coreml",  // the Core ML turn model, never installs/turn (M9.T05)
                         path: (VoiceModelRole.turn.developerDirectory(in: root) ?? root.appendingPathComponent("turn")).path, footprintBytes: 1),
        .tts: slot("tts", "tts"),
    ])
}

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct BargeInFixtureTests {
    struct Manifest: Decodable { var items: [Item] }
    struct Item: Decodable {
        var item: Int
        var room: Int
        var onset_ms: Int
        var tts_text: String
        var user_text: String
        var file: String { String(format: "item%02d-room%d", item, room) }
    }

    static let root = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/barge-in")
    /// This checkout (the test's own sources), not the fixtures' parent: evidence lands in the tree under test.
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let at = repo.appendingPathComponent("build/at/AT-282")
    /// The TTS audio of each item (24 kHz, all the sink received) for the aligner; local only (build/ is ignored).
    static let played = repo.appendingPathComponent("build/at282-played")
    static let models = DirectVoiceModels()

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    struct Run {
        var trace: [String: Any] = [:]
        var stored: String
        /// The played sample at the stop (24 kHz, the sink's clock) and each chunk the sink received: its text, first
        /// sample on that clock and a file holding its audio (for the aligner).
        var playedSample: Int = 0
        var chunks: [(text: String, start: Int, wav: URL)] = []
        var silentMs: Double?
        var cancelMs: Double?
        var finals: [String]
        var spoken: [String]
        var stopped: Bool
    }

    /// One item: speak `reply` (word deltas), inject the user stem at the first chunk's start, wait for the stop and the
    /// interrupting utterance's final.
    static func run(_ item: Item, reply: String, interrupt: Bool = true) async throws -> Run {
        VoiceEnvironment.lockDown()
        let sink = VoiceSink()
        let mic = RealtimeInjector()
        let out = RecordingSink()
        let start = VoiceSessionStart(chatID: UUID(), locale: "en", voiceID: "af_heart")
        let parts = try await VoiceSessionService.standardParts(start, DirectVoiceModels.set, provider: models, live: mic, sink: out)
        let session = VoiceSession(start: start, parts: parts, emit: sink.emit)
        try await session.begin()
        defer { Task { await session.end() } }
        // The user turn that produces the reply is skipped: the session goes straight to thinking via the app's reply.
        let turn = UUID()
        for w in reply.split(separator: " ", omittingEmptySubsequences: false) {
            await session.control(.speak(text: String(w) + " ", turnID: turn))
        }
        await session.control(.speakEnd(turnID: turn))
        // Bounded on the real condition: the first synthesis of a cold Kokoro (model compile) can take > 10 s on a
        // loaded GPU; the barge-in measurements start only after the first chunk plays.
        try await wait(60) { sink.voice.contains(.ttsStarted(chunkIndex: 0)) }
        if !interrupt {
            try await wait(60) { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
            let spoken = sink.voice.compactMap { e -> String? in if case .speakingText(let s) = e { s } else { nil } }
            await session.end()
            return Run(stored: reply, silentMs: nil, cancelMs: nil, finals: [], spoken: spoken, stopped: false)
        }
        let user = try VoiceAudioConverter.readFile(root.appendingPathComponent("\(item.file)-user.wav"))
        let injected = mic.inject(user)
        // Onset = the user's first 32 ms frame ≥ −40 dBFS in the stem (the V6 rule): `onset_ms` marks where the
        // LibriSpeech file starts, and those files open with 0.2–0.6 s of near-silence.
        let onsetNs = injected + UInt64(firstVoicedMs(user, from: item.onset_ms) * 1_000_000)
        try await wait(15) { sink.voice.contains { if case .ttsStopped(_, .bargeIn) = $0 { true } else { false } } }
        let stopNs = VoiceAudioSignposts.now()
        let playedMs = sink.voice.compactMap { e -> Double? in if case .ttsStopped(let ms, .bargeIn) = e { ms } else { nil } }.first ?? 0
        let offset = sink.voice.compactMap { e -> Int? in if case .spokenSpan(let id, let o) = e, id == turn { o } else { nil } }.last ?? 0
        let stored = String(reply.utf16.prefix(offset)) ?? ""
        // What was heard is decided after the run (`heardWords`): keep everything the sink received (the stop sample
        // splits it) for the aligner, chunk by chunk below.
        var playedSample = Int((playedMs / 1_000 * 24_000).rounded())  // the stop trace's exact count below
        let audio = out.take()
        try await wait(15) { sink.finals.count >= 1 }
        let t = await session.timings
        let silent = t.ttsSilent.last.map { Double(Int64($0) - Int64(onsetNs)) / 1e6 }
        let cancel = Double(Int64(stopNs) - Int64(onsetNs)) / 1e6
        let spoken = sink.voice.compactMap { e -> String? in if case .speakingText(let s) = e { s } else { nil } }
        await session.end()
        var trace: [String: Any] = [:]
        var chunks: [(text: String, start: Int, wav: URL)] = []
        if let tr = await session.lastStopTrace {
            playedSample = tr.played
            try FileManager.default.createDirectory(at: played, withIntermediateDirectories: true)
            for (k, e) in tr.entries.enumerated() where e.startSample < audio.count {
                let wav = played.appendingPathComponent("\(item.file)-\(k).wav")
                try writeWAV(Array(audio[e.startSample..<min(audio.count, e.startSample + e.sampleCount)]), sampleRate: 24_000, to: wav)
                chunks.append((e.chunk.text, e.startSample, wav))
            }
            trace["played"] = tr.played
            trace["entries"] = tr.entries.map { e -> [String: Any] in
                ["text": e.chunk.text, "source": [e.chunk.source.lowerBound, e.chunk.source.upperBound],
                 "start": e.startSample, "count": e.sampleCount, "word_starts": e.wordStarts ?? []]
            }
        }
        return Run(trace: trace, stored: stored, playedSample: playedSample, chunks: chunks, silentMs: silent, cancelMs: cancel,
                   finals: sink.finals.map(\.text), spoken: spoken, stopped: true)
    }

    /// AT-282 AC2 reference (A-M9-T05-AT282b): how many reply words had started playing at the stop — the words whose
    /// acoustic onset (forced alignment) precedes `playedSample`. `onsets` are in reply-word order (`words`).
    static func heardWords(onsets: [Int], playedSample: Int) -> Int { onsets.filter { $0 < playedSample }.count }

    /// Word onsets (samples of each file) of `jobs` (id, wav, text) by `tools/voice/word-onsets.py`, one batch.
    static func alignOnsets(_ jobs: [(id: String, wav: URL, text: String)]) throws -> [String: [Int]] {
        let dir = VoiceTestAudio.tempDir("at282-align")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("jobs.json"), output = dir.appendingPathComponent("onsets.json")
        try JSONSerialization.data(withJSONObject: jobs.map { ["id": $0.id, "wav": $0.wav.path, "text": $0.text] }).write(to: input)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", repo.appendingPathComponent("tools/voice/word-onsets.py").path, input.path, output.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AntiChatError.voice("aligner", "word-onsets.py exit \(p.terminationStatus)") }
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: [String: Any]] ?? [:]
        return doc.mapValues { (($0["words"] as? [[String: Any]]) ?? []).compactMap { $0["start"] as? Int } }
    }

    static func firstVoicedMs(_ x: [Float], from ms: Int, dBFS: Double = -40) -> Double {
        var i = ms * 16
        while i + 512 <= x.count {
            if rmsDBFS(Array(x[i..<(i + 512)])) >= dBFS { return Double(i) / 16 }
            i += 512
        }
        return Double(ms)
    }

    static func wait(_ seconds: Double, _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while !cond() {
            if ContinuousClock.now > end { throw AntiChatError.voice("timeout", "barge-in fixture") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func loadAverage() -> [Double] {
        var v = [Double](repeating: 0, count: 3)
        getloadavg(&v, 3)
        return v
    }

    static func write(_ doc: [String: Any], _ name: String) throws {
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: at.appendingPathComponent(name))
    }

    /// AC2 + AC1 + R-052 AC3 + NFR-V3 over every item (≥ 30).
    @Test func testStoredTextEqualsSpokenSpan() async throws {
        let items = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.root.appendingPathComponent("manifest.json"))).items
        #expect(items.count >= 30)
        var rows: [[String: Any]] = []
        var silent: [Double] = []
        var cancel: [Double] = []
        let loadBefore = Self.loadAverage()
        var runs: [(Item, Run)] = []
        for item in items { runs.append((item, try await Self.run(item, reply: item.tts_text))) }
        let onsets = try Self.alignOnsets(runs.flatMap { i, r in
            r.chunks.enumerated().map { k, c in ("\(i.file)-\(k)", c.wav, c.text) }
        })
        for (item, r) in runs {
            let storedWords = Self.words(r.stored).count
            // Onsets on the sink's clock, chunk by chunk; reply words of chunks the sink never received are not heard.
            var wordOnsets: [Int] = []
            for (k, c) in r.chunks.enumerated() {
                let o = onsets["\(item.file)-\(k)"] ?? []
                #expect(o.count == Self.words(c.text).count, "\(item.file) chunk \(k): aligned \(o.count) of «\(c.text)»")
                wordOnsets += o.map { c.start + $0 }
            }
            let heardWords = Self.heardWords(onsets: wordOnsets, playedSample: r.playedSample)
            let ok = abs(storedWords - heardWords) <= 1
            #expect(ok, "\(item.file): stored \(storedWords) words «\(r.stored)», heard \(heardWords)")
            #expect(r.finals.count == 1, "\(item.file): the interrupting utterance is answered: \(r.finals)")
            // AC1: the first chunk is the first clause with ≥ 4 words.
            let first = ClauseChunker.chunks(item.tts_text).first ?? ""
            #expect(r.spoken.first == first && Self.words(first).count >= 4, "\(item.file): first chunk \(r.spoken.first ?? "-")")
            if let s = r.silentMs { silent.append(s) }
            if let c = r.cancelMs { cancel.append(c) }
            rows.append(["file": item.file, "onset_ms": item.onset_ms, "stored": r.stored, "stored_words": storedWords,
                         "heard_words": heardWords, "ok": ok, "word_onsets": wordOnsets, "onset_to_silent_ms": r.silentMs ?? -1,
                         "onset_to_cancel_ms": r.cancelMs ?? -1, "final": r.finals.first ?? "", "trace": r.trace,
                         "reply": item.tts_text])
        }
        let okCount = rows.filter { $0["ok"] as? Bool == true }.count
        try Self.write(["n": rows.count, "ok": okCount, "method": "inject", "label": "[IN-PIPELINE]",
                        "reference": "reply words whose forced-aligned acoustic onset (MFA 3.4.3 english_us_arpa, tools/voice/word-onsets.py) precedes the played sample (A-M9-T05-AT282b)", "items": rows,
                        "loadavg": [loadBefore, Self.loadAverage()]], "spans.json")
        func p(_ xs: [Double], _ q: Double) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        try Self.write(["n": silent.count, "method": "inject", "label": "[IN-PIPELINE]",
                        "onset_to_silent_ms": silent, "onset_to_cancel_ms": cancel,
                        "silent_p50": p(silent, 0.5), "silent_p95": p(silent, 0.95),
                        "cancel_p50": p(cancel, 0.5), "cancel_p95": p(cancel, 0.95),
                        "onset": "the user stem's first 32 ms frame >= -40 dBFS after onset_ms (the V6 rule), from the injection start",
                        "cancel": "the helper's cancel signal (ttsStopped(.bargeIn) emitted); the app's TurnController cancel ack follows over XPC",
                        "loadavg": [loadBefore, Self.loadAverage()]], "v3.json")
        #expect(okCount == rows.count)
    }

    /// AC3: Markdown never spoken (the TTS input log has no Markdown symbols; a code fence → "code omitted").
    @Test func testNoMarkdownSpoken() async throws {
        let items = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.root.appendingPathComponent("manifest.json"))).items
        let reply = "## Route\n\nThe **quickest** way is the `ring road`, see [map](https://maps.example.com/x).\n\n```sh\nopen maps\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n" + items[0].tts_text
        let r = try await Self.run(items[0], reply: reply, interrupt: false)
        #expect(!r.spoken.isEmpty)
        for s in r.spoken { #expect(!s.contains { SpeakableText.forbidden.contains($0) }, "spoken «\(s)»") }
        #expect(r.spoken.contains("code omitted."), "\(r.spoken)")
        #expect(r.spoken.first == "Route")
        try Self.write(["reply": reply, "tts_input": r.spoken], "markdown.json")
        #expect(!r.spoken.joined(separator: " ").contains("open maps"))
    }

    /// AC1 on its own (one item).
    @Test func testFirstChunkIsFirstClause() async throws {
        let items = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.root.appendingPathComponent("manifest.json"))).items
        let r = try await Self.run(items[1], reply: items[1].tts_text)
        let first = ClauseChunker.chunks(items[1].tts_text).first ?? ""
        #expect(r.spoken.first == first)
        #expect(Self.words(first).count >= 4)
    }
}

/// The AT-282 AC2 reference without models: a word counts once its acoustic onset precedes the played sample.
struct HeardReplyWordsTests {
    @Test func wordsCountFromTheirOnset() {
        let onsets = [8_400, 12_000, 21_000, 25_200]
        #expect(BargeInFixtureTests.heardWords(onsets: onsets, playedSample: 0) == 0)
        #expect(BargeInFixtureTests.heardWords(onsets: onsets, playedSample: 12_000) == 1)  // "a word whose audio has started"
        #expect(BargeInFixtureTests.heardWords(onsets: onsets, playedSample: 12_001) == 2)
        #expect(BargeInFixtureTests.heardWords(onsets: onsets, playedSample: 99_999) == 4)
    }
}
