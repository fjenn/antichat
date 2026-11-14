import AntiChatEngineProtocol
import Darwin
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct TurnSplitFixtureTests {
    struct Manifest: Decodable { var items: [Item] }
    struct Item: Decodable {
        var file: String
        var pause_ms: Int
        var expected_turns: Int
    }

    static let fixtures = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/turn-split-50")
    static let models = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    static let at = VoiceTestAudio.fixturesRoot!
        .deletingLastPathComponent().appendingPathComponent("build/at/AT-283")

    static func modelDirectory(_ key: String) -> URL {
        // `turn`: the Core ML turn model by its catalog key (turn-coreml), never the ONNX-only installs/turn (M9.T05).
        if key == "turn" { return VoiceModelRole.turn.developerDirectory(in: models) ?? models.appendingPathComponent("turn") }
        let legacy = models.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return models.appendingPathComponent("installs/\(key)")
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    }

    static func detector() throws -> TurnDetector {
        VoiceEnvironment.lockDown()
        let vad = try SileroVADProvider(directory: modelDirectory("vad-files"))
        let turn = try SmartTurnLoader.load(turnDirectory: modelDirectory("turn"))
        return TurnDetector(vad: vad, smartTurn: turn)
    }

    static func mixed(_ speech: [Float], noise: [Float]?) -> [Float] {
        guard let noise, !noise.isEmpty else { return speech }
        let gain = Float(pow(10, -20.0 / 20.0))
        return speech.enumerated().map { $1 + noise[$0 % noise.count] * gain }
    }

    /// One turn end as the tests see it: why, the turn's first sample, its last voiced sample, the frame that decided.
    struct End {
        var reason: String
        var start: Int
        var voiced: Int
        var decided: Int
    }

    /// Silence after the audio (the open-sentence cap is 2 s, so a turn that never agrees still ends inside it).
    static let tailSamples = 40_000

    /// Feeds `audio` through `d` in 32 ms frames like the capture worker, and — like the session — transcribes the
    /// turn so far (Parakeet, from 0.5 s before the onset) at each `.paused` and hands the text to the detector three
    /// frames later (≈ the recogniser's latency; deterministic). `stt` nil = no transcripts (agreement never holds).
    static func runTurns(_ d: TurnDetector, audio: [Float], stt: ParakeetModel?) async -> [End] {
        var ends: [End] = []
        var fed = 0
        var turnStart = 0
        var due: (atFed: Int, text: String, voiced: Int)?
        d.expectsTranscript = stt != nil
        func take(_ events: [TurnDetectorEvent]) async {
            for e in events {
                switch e {
                case .speechStarted(let sample): turnStart = sample
                case .paused(let voiced):
                    if let stt {
                        let from = max(0, turnStart - 8_000)
                        let text = (try? await stt.transcribe(Array(audio[from..<min(fed, audio.count)])).text) ?? ""
                        due = (fed + 3 * 512, text, voiced)
                    }
                case .turnEnded(let reason, let start, _, let voiced, _, _):
                    ends.append(End(reason: reason.rawValue, start: start, voiced: voiced, decided: fed))
                    due = nil
                default: break
                }
            }
        }
        for offset in stride(from: 0, to: audio.count, by: 512) {
            let frame = Array(audio[offset..<min(offset + 512, audio.count)])
            fed += frame.count
            if let t = due, fed >= t.atFed {
                due = nil
                if let end = d.setTranscript(t.text, voicedSample: t.voiced) { await take([end]) }
            }
            await take(d.process(samples: frame))
        }
        await take(d.flush())
        return ends
    }

    static func write(_ document: [String: Any], named name: String) throws {
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: at.appendingPathComponent(name))
    }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        getloadavg(&values, 3)
        return values
    }

    @Test func scriptedVoiceUsesInjectedCaptureTap() async throws {
        let dir = VoiceTestAudio.tempDir("turn-script")
        let script = dir.appendingPathComponent("turn.jsonl")
        let wav = Self.fixtures.appendingPathComponent("01.wav").path
        try JSONSerialization.data(withJSONObject: ["t_ms": 0, "wav": wav]).write(to: script)
        let source = try ScriptedVoice(script: script, speed: 50)
        let audio = VoiceAudioEngine(injected: source)
        let detector = try Self.detector()
        let ends = Mutex(0)
        try audio.start { samples in
            for event in detector.process(samples: samples) {
                if case .turnEnded = event { ends.withLock { $0 += 1 } }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ends.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        audio.stop()
        #expect(!audio.isEchoCancellationActive)
        #expect(ends.withLock { $0 } == 1)
    }

    @Test func fiftyUtterancesCleanAndNoise() async throws {
        let items = try Self.manifest().items
        #expect(items.count == 50)
        let d = try Self.detector()
        let stt = try await ParakeetModel.load(directory: Self.modelDirectory("stt"))
        let noiseRoot = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/noise")
        for bed in [nil, "cafe", "fan", "keyboard"] {
            let noise = try bed.map { try VoiceAudioConverter.readFile(noiseRoot.appendingPathComponent("\($0).wav")) }
            var rows: [[String: Any]] = []
            var falseSplits = 0
            for item in items {
                d.reset()
                let speech = try VoiceAudioConverter.readFile(Self.fixtures.appendingPathComponent(item.file))
                let audio = Self.mixed(speech + [Float](repeating: 0, count: Self.tailSamples), noise: noise)
                let ends = await Self.runTurns(d, audio: audio, stt: stt)
                let reasons = ends.map(\.reason)
                if ends.count != item.expected_turns { falseSplits += 1 }
                rows.append([
                    "file": item.file,
                    "pause_ms": item.pause_ms,
                    "expected_turns": item.expected_turns,
                    "actual_turns": ends.count,
                    "reasons": reasons,
                ])
            }
            let rate = 100 * Double(falseSplits) / Double(items.count)
            let name = bed ?? "clean"
            try Self.write([
                "tier": ProcessInfo.processInfo.environment["ANTICHAT_TIER"] ?? "T1",
                "method": "inject",
                "label": "[IN-PIPELINE]",
                "noise": name,
                "noise_gain_db": bed == nil ? 0 : -20,
                "n": items.count,
                "false_splits": falseSplits,
                "false_split_percent": rate,
                "pass": rate <= 2,
                "thresholds": Self.describe(d.thresholds),
                "loadavg": Self.loadAverage(),
                "items": rows,
            ], named: bed.map { "turn-split-\($0).json" } ?? "turn-split.json")
            #expect(falseSplits <= 1, "\(name): \(falseSplits) false splits")
        }
    }

    /// Tuning (M3.T09 step 5): `ANTICHAT_TURN_TUNE=<file.json>` holds an array of `TurnThresholds`; each candidate
    /// runs on the clean fixture and is written to `build/at/AT-283/tuning-<date>-<n>.json`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_TURN_TUNE"] != nil))
    func tuneThresholds() async throws {
        let items = try Self.manifest().items
        let speech = try items.map { try VoiceAudioConverter.readFile(Self.fixtures.appendingPathComponent($0.file)) }
        let noiseRoot = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/noise")
        let vad = try SileroVADProvider(directory: Self.modelDirectory("vad-files"))
        let turn = try SmartTurnLoader.load(turnDirectory: Self.modelDirectory("turn"))
        let stt = try await ParakeetModel.load(directory: Self.modelDirectory("stt"))
        let candidates = try JSONDecoder().decode([TurnThresholds].self, from: Data(contentsOf: URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_TURN_TUNE"]!)))
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let dictation = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation")
        let questions = try (1...20).map { i -> (String, [Float]) in
            let name = String(format: "q%02d.wav", i)
            return (name, try VoiceAudioConverter.readFile(dictation.appendingPathComponent(name)))
        }
        for (n, thresholds) in candidates.enumerated() {
            let d = TurnDetector(vad: vad, smartTurn: turn, thresholds: thresholds)
            var beds: [[String: Any]] = []
            for bed in [nil, "cafe", "fan", "keyboard"] {
                let noise = try bed.map { try VoiceAudioConverter.readFile(noiseRoot.appendingPathComponent("\($0).wav")) }
                var falseSplits = 0
                var turns: [Int] = []
                var endMs: [Double] = []
                var splits: [[String: Any]] = []
                for (i, samples) in speech.enumerated() {
                    d.reset()
                    // Fed in 32 ms frames, like the capture worker: the end of turn is the frame that decided it.
                    let audio = Self.mixed(samples + [Float](repeating: 0, count: Self.tailSamples), noise: noise)
                    let ends = await Self.runTurns(d, audio: audio, stt: stt)
                    turns.append(ends.count)
                    if ends.count != 1 {
                        falseSplits += 1
                        splits.append(["file": items[i].file, "pause_ms": items[i].pause_ms,
                                       "ends": ends.map { ["reason": $0.reason, "start_ms": $0.start / 16,
                                                           "last_voiced_ms": $0.voiced / 16, "decided_ms": $0.decided / 16] }])
                    }
                    // Endpointing (V2 stage 1): last voiced frame → the frame that ended the turn.
                    if let first = ends.first { endMs.append(Double(max(0, first.decided - first.voiced)) / 16) }
                }
                let sortedEnd = endMs.sorted()
                beds.append(["noise": bed ?? "clean", "false_splits": falseSplits,
                             "false_split_percent": 100 * Double(falseSplits) / 50, "turn_counts": turns,
                             "endpointing_p50_ms": sortedEnd.isEmpty ? -1 : sortedEnd[(sortedEnd.count - 1) / 2],
                             "endpointing_p90_ms": sortedEnd.isEmpty ? -1 : sortedEnd[sortedEnd.count * 9 / 10],
                             "splits": splits])
            }
            // Endpointing on the V1 utterances (`dictation/q01…q20`, clean, 1.6 s of silence after each): the stage-1
            // number V1 pays for; a candidate must not buy fewer false splits with a slower turn end.
            var qEnd: [Double] = []
            var qRows: [[String: Any]] = []
            for (name, samples) in questions {
                d.reset()
                let ends = await Self.runTurns(d, audio: samples + [Float](repeating: 0, count: Self.tailSamples), stt: stt)
                let first = ends.first
                let ms = first.map { Double(max(0, $0.decided - $0.voiced)) / 16 } ?? -1
                if ms >= 0 { qEnd.append(ms) }
                qRows.append(["file": name, "turns": ends.count, "reason": first?.reason ?? "none", "endpointing_ms": ms])
            }
            let qs = qEnd.sorted()
            try Self.write([
                "date": date,
                "kind": "tuning",
                "fixture": "turn-split-50",
                "thresholds": Self.describe(thresholds),
                "beds": beds,
                "v1_utterances": ["endpointing_p50_ms": qs.isEmpty ? -1 : qs[(qs.count - 1) / 2],
                                  "endpointing_p90_ms": qs.isEmpty ? -1 : qs[qs.count * 9 / 10], "items": qRows],
                "loadavg": Self.loadAverage(),
            ], named: "tuning-\(date)-\(ProcessInfo.processInfo.environment["ANTICHAT_TURN_TUNE_TAG"] ?? "")\(n).json")
        }
    }

    static func describe(_ t: TurnThresholds) -> [String: Any] {
        ["onsetMs": t.onsetMs, "holdMs": t.holdMs, "smartTurnThreshold": t.smartTurnThreshold,
         "rechecks": t.rechecks.map { ["afterMs": $0.afterMs, "threshold": $0.threshold] }, "maxSilenceMs": t.maxSilenceMs,
         "levelGateDb": t.levelGateDb.map { Double($0) } ?? NSNull(),
         "requireSentenceEnd": t.requireSentenceEnd ?? false,
         "sentenceEnd": t.sentenceEnd.map { ["afterMs": $0.afterMs, "threshold": $0.threshold] as [String: Any] } ?? NSNull(),
         "sentenceCapMs": t.sentenceCapMs ?? NSNull(),
         "sentenceStable": t.sentenceStable.map { ["probesMs": $0.probesMs, "threshold": $0.threshold] as [String: Any] } ?? NSNull(),
         "openEnd": t.openEnd.map { ["afterMs": $0.afterMs, "threshold": $0.threshold] as [String: Any] } ?? NSNull()]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_V283"] == "1"))
    func eagerSTTLatency() async throws {
        VoiceEnvironment.lockDown()
        let n = Int(ProcessInfo.processInfo.environment["ANTICHAT_V283_RUNS"] ?? "") ?? 20
        let items = Array(try Self.manifest().items.prefix(n))
        let parakeet = try await ParakeetModel.load(directory: Self.modelDirectory("stt"))
        let eou = try await ParakeetEOUModel.load(directory: Self.modelDirectory("stt-eou"))
        let turnModel = try SmartTurnLoader.load(turnDirectory: Self.modelDirectory("turn"))
        try turnModel.prewarm()
        var rows: [[String: Any]] = []
        let loadBefore = Self.loadAverage()

        for item in items {
            let vad = try SileroVADProvider(directory: Self.modelDirectory("vad-files"))
            let detector = TurnDetector(vad: vad, smartTurn: turnModel)
            let backend = ParakeetBackend(model: parakeet, eou: eou)
            let transcriber = EagerTurnTranscriber(backend: backend)
            let eouSignalled = Mutex(false)
            try await transcriber.start(locale: Locale(identifier: "en"), onEOU: {
                eouSignalled.withLock { $0 = true }
            })
            var audio = try VoiceAudioConverter.readFile(Self.fixtures.appendingPathComponent(item.file))
            audio += [Float](repeating: 0, count: 32_000)
            var ended: TurnDetectorEvent?
            for offset in stride(from: 0, to: audio.count, by: 512) {
                let frame = Array(audio[offset..<min(offset + 512, audio.count)])
                transcriber.append(samples: frame)
                for event in detector.process(samples: frame) {
                    if case .turnEnded = event { ended = event }
                }
                if eouSignalled.withLock({ value in defer { value = false }; return value }) {
                    if let event = detector.endOfUtterance() { ended = event }
                }
                if ended != nil { break }
                try await Task.sleep(for: .milliseconds(32))
            }
            guard let ended else {
                await transcriber.cancel()
                Issue.record("\(item.file): no turn end")
                continue
            }
            let final = try await transcriber.finish(turn: ended)
            guard case .turnEnded(let reason, _, _, _, let endNs, let voicedNs) = ended else { continue }
            let finalNs = VoiceAudioSignposts.now()
            rows.append([
                "file": item.file,
                "reason": reason.rawValue,
                "turn_to_final_ms": Double(finalNs - endNs) / 1e6,
                "last_voiced_to_final_ms": voicedNs.map { Double(finalNs - $0) / 1e6 } ?? -1,
                "transcript_chars": final.text.count,
            ])
        }
        let turnValues = rows.map { $0["turn_to_final_ms"] as! Double }
        let voicedValues = rows.compactMap { $0["last_voiced_to_final_ms"] as? Double }.filter { $0 >= 0 }
        let sorted = turnValues.sorted()
        let p50 = sorted.isEmpty ? Double.infinity : sorted[(sorted.count - 1) / 2]
        try Self.write([
            "tier": "T1",
            "method": "inject",
            "label": "[IN-PIPELINE]",
            "n": rows.count,
            "turn_to_final_ms": turnValues,
            "last_voiced_to_final_ms": voicedValues,
            "turn_to_final_p50_ms": p50,
            "pass": p50 <= 300 && rows.count == items.count,
            "loadavg_before": loadBefore,
            "loadavg_after": Self.loadAverage(),
            "runs": rows,
        ], named: "eos.json")
        #expect(rows.count == items.count)
        #expect(p50 <= 300)
    }
}
