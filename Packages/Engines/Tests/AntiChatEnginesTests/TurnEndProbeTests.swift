// M3.T09 tuning probe (`@realModels`, ANTICHAT_TURN_PROBE=1): what stage 2 can tell apart. For every `turn-split-50`
// item at its inserted pause (a turn that must NOT end) and every `dictation/q01…q20` at its end (a turn that must end,
// the V1 utterances), smart-turn's probability after 200…1100 ms of silence, the Parakeet text of the turn so far,
// clean and under each `noise/` bed at −20 dB.
//   ANTICHAT_VOICE_IT=1 ANTICHAT_TURN_PROBE=1 swift test --filter TurnEndProbeTests → build/at/AT-283/probe-<date>.json
import Foundation
import SpeechSwiftVendored
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"
                && ProcessInfo.processInfo.environment["ANTICHAT_TURN_PROBE"] == "1"))
struct TurnEndProbeTests {
    struct Item: Decodable {
        var file: String
        var pause_ms: Int
        var pause_at_ms: Int
    }

    struct Manifest: Decodable { var items: [Item] }

    static let silences = [200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100]

    @Test func probe() async throws {
        VoiceEnvironment.lockDown()
        let root = VoiceTestAudio.fixturesRoot!
        let turn = try SmartTurnLoader.load(turnDirectory: TurnSplitFixtureTests.modelDirectory("turn"))
        let stt = try await ParakeetModel.load(directory: TurnSplitFixtureTests.modelDirectory("stt"))
        let items = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent(
            "audio/turn-split-50/manifest.json"))).items
        let beds = (ProcessInfo.processInfo.environment["ANTICHAT_TURN_PROBE_BEDS"] ?? "clean,cafe,fan,keyboard")
            .split(separator: ",").map(String.init)
        var cases: [(kind: String, file: String, speech: [Float])] = []
        for item in items {
            let a = try VoiceAudioConverter.readFile(root.appendingPathComponent("audio/turn-split-50/\(item.file)"))
            // The audio up to the inserted pause; the pause itself is silence in the fixture.
            cases.append(("pause", item.file, Array(a.prefix(item.pause_at_ms * 16))))
        }
        for i in 1...20 {
            let name = String(format: "q%02d.wav", i)
            cases.append(("end", name, try VoiceAudioConverter.readFile(root.appendingPathComponent("audio/dictation/\(name)"))))
        }
        var out: [String: Any] = ["silences_ms": Self.silences]
        for bed in beds {
            let noise = bed == "clean" ? nil
                : try VoiceAudioConverter.readFile(root.appendingPathComponent("audio/noise/\(bed).wav"))
            var rows: [[String: Any]] = []
            for c in cases {
                let full = TurnSplitFixtureTests.mixed(c.speech + [Float](repeating: 0, count: 1100 * 16), noise: noise)
                var ps: [Double] = []
                for s in Self.silences {
                    let upTo = Array(full.prefix(c.speech.count + s * 16))
                    let window = Array(upTo.suffix(SmartTurnModel.windowSeconds * 16_000))
                    ps.append(Double((try? turn.turnCompleteProbability(audio: window, sampleRate: 16_000)) ?? -1))
                }
                var row: [String: Any] = ["kind": c.kind, "file": c.file, "p": ps]
                if bed == "clean" { row["text"] = (try? await stt.transcribe(c.speech).text) ?? "" }
                rows.append(row)
            }
            out[bed] = rows
        }
        let dir = root.deletingLastPathComponent().appendingPathComponent("build/at/AT-283")
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("probe-\(date).json"))
    }
}

// M9.T05 trace (`@realModels`, ANTICHAT_TURN_TRACE=1): what the live detector sees at every pause, fed frame by frame
// like `TurnSplitFixtureTests.runTurns` — the pause transcript (Parakeet from 0.5 s before the onset to the `.paused`
// frame) and whether it is a finished sentence, the real silence length, and smart-turn at each candidate silence
// length on the detector's own window. turn-split-50 × 4 beds + dictation q01…q20 (clean). Rules are then replayed
// offline (`tools/voice/turn-replay.py`).  → build/at/AT-283/trace-<date>.json
private final class NeverDone: TurnCompletionProvider, @unchecked Sendable {
    func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float { 0 }
}

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"
                && ProcessInfo.processInfo.environment["ANTICHAT_TURN_TRACE"] == "1"))
struct TurnEndTraceTests {
    static let silences = [192, 224, 256, 288, 320, 352, 384, 416, 448, 480, 512, 608, 704, 800, 928, 1024, 1216, 1504]

    @Test func trace() async throws {
        VoiceEnvironment.lockDown()
        let root = VoiceTestAudio.fixturesRoot!
        let turn = try SmartTurnLoader.load(turnDirectory: TurnSplitFixtureTests.modelDirectory("turn"))
        let stt = try await ParakeetModel.load(directory: TurnSplitFixtureTests.modelDirectory("stt"))
        let vad = try SileroVADProvider(directory: TurnSplitFixtureTests.modelDirectory("vad-files"))
        // Stage 1 only (onset, level gate, pauses); nothing but the 2 s cap ends a turn.
        let t = TurnThresholds(onsetMs: 250, holdMs: 300, smartTurnThreshold: 2, maxSilenceMs: 2000, levelGateDb: 10)
        let d = TurnDetector(vad: vad, smartTurn: NeverDone(), thresholds: t)
        let items = try TurnSplitFixtureTests.manifest().items
        var cases: [(kind: String, file: String, audio: [Float])] = []
        for item in items {
            cases.append(("pause", item.file, try VoiceAudioConverter.readFile(TurnSplitFixtureTests.fixtures.appendingPathComponent(item.file))))
        }
        for i in 1...20 {
            let name = String(format: "q%02d.wav", i)
            cases.append(("end", name, try VoiceAudioConverter.readFile(root.appendingPathComponent("audio/dictation/\(name)"))))
        }
        let beds = (ProcessInfo.processInfo.environment["ANTICHAT_TURN_PROBE_BEDS"] ?? "clean,cafe,fan,keyboard")
            .split(separator: ",").map(String.init)
        var out: [String: Any] = ["silences_ms": Self.silences]
        for bed in beds {
            let noise = bed == "clean" ? nil
                : try VoiceAudioConverter.readFile(root.appendingPathComponent("audio/noise/\(bed).wav"))
            var rows: [[String: Any]] = []
            for c in cases where bed == "clean" || c.kind == "pause" {
                let audio = TurnSplitFixtureTests.mixed(c.audio + [Float](repeating: 0, count: TurnSplitFixtureTests.tailSamples), noise: noise)
                d.reset()
                d.expectsTranscript = false
                var turnStart = 0
                var fed = 0
                var lastVoiced: Int?
                var open: [String: Any]?
                var openVoiced = 0
                var pauses: [[String: Any]] = []
                func close(_ silenceSamples: Int) {
                    guard var p = open else { return }
                    p["silence_ms"] = silenceSamples / 16
                    pauses.append(p)
                    open = nil
                }
                for offset in stride(from: 0, to: audio.count, by: 512) {
                    let frame = Array(audio[offset..<min(offset + 512, audio.count)])
                    fed += frame.count
                    let events = d.process(samples: frame)
                    if d.isInTurn, d.lastSpeechProbability >= 0.5 {
                        if open != nil { close(fed - frame.count - openVoiced) }
                        lastVoiced = fed
                    }
                    for e in events {
                        switch e {
                        case .speechStarted(let s): turnStart = s
                        case .paused(let voiced):
                            let from = max(0, turnStart - 8_000)
                            let text = (try? await stt.transcribe(Array(audio[from..<min(fed, audio.count)])).text) ?? ""
                            var ps: [String: Double] = [:]
                            for s in Self.silences {
                                let end = min(audio.count, voiced + s * 16)
                                let first = max(turnStart, end - SmartTurnModel.windowSeconds * 16_000)
                                ps["\(s)"] = Double((try? turn.turnCompleteProbability(audio: Array(audio[first..<end]), sampleRate: 16_000)) ?? -1)
                            }
                            open = ["voiced_ms": voiced / 16, "start_ms": turnStart / 16, "text": text,
                                    "sentence": TurnDetector.endsSentence(text), "p": ps]
                            openVoiced = voiced
                        case .turnEnded:
                            close(fed - openVoiced)
                        default: break
                        }
                    }
                }
                for e in d.flush() { if case .turnEnded = e { close(fed - openVoiced) } }
                close(fed - openVoiced)
                _ = lastVoiced
                rows.append(["kind": c.kind, "file": c.file, "pauses": pauses])
            }
            out[bed] = rows
        }
        let dir = root.deletingLastPathComponent().appendingPathComponent("build/at/AT-283")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("trace-\(date).json"))
    }
}
