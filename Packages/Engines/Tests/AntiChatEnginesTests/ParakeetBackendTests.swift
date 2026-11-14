// M3.T03 step 8 (@realModels; NFR-V9 smoke, R-050 AC2 offline): ParakeetBackend on the dev model store
// (`stt`, `stt-eou`, `vad-files` from `make models-dev`), offline (ModelHub.offlineMode before any FluidAudio call).
//   ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=… make test-unit FILTER=ParakeetBackendTests   (wrap in gpu-run.sh shared)
// - WER on the first 20 LibriSpeech test-clean-200 utterances ≤ 6 % (NFR-V9 T1+), batch final path.
// - Live partials on dictation q01 through both partial paths (EOU streaming English; 500 ms re-run window).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

extension Tag {
    @Tag static var realModels: Self
}

enum WER {
    static func words(_ s: String) -> [String] {
        var out = ""
        for u in s.uppercased().unicodeScalars {
            let keep = CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) || u == "'"
            out.unicodeScalars.append(keep ? u : " ")
        }
        return out.split(separator: " ").map(String.init)
    }

    /// Word edit distance (substitutions + insertions + deletions).
    static func errors(_ ref: [String], _ hyp: [String]) -> Int {
        var prev = Array(0...hyp.count)
        for (i, r) in ref.enumerated() {
            var cur = [i + 1] + [Int](repeating: 0, count: hyp.count)
            for (j, h) in hyp.enumerated() { cur[j + 1] = min(prev[j] + (r == h ? 0 : 1), prev[j + 1] + 1, cur[j] + 1) }
            prev = cur
        }
        return prev[hyp.count]
    }
}

@Suite(.tags(.realModels), .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil),
       .serialized)
struct ParakeetBackendTests {
    static let models = ProcessInfo.processInfo.environment["ANTICHAT_MODELS"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")

    @Test func werOnTwentyLibriSpeechUtterances() async throws {
        VoiceEnvironment.lockDown()
        let model = try await ParakeetModel.load(directory: Self.models.appendingPathComponent("stt"))
        let dir = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/librispeech-test-clean-200")
        let tsv = try String(contentsOf: dir.appendingPathComponent("transcripts.tsv"), encoding: .utf8)
        var all: [[String]] = []
        for line in tsv.split(separator: "\n") {
            let cols = line.split(separator: "\t").map(String.init)  // id, duration_s, transcript
            if cols.count == 3, cols[0] != "id" { all.append([cols[0], cols[2]]) }
        }
        all.sort { $0[0] < $1[0] }
        let rows = all.prefix(20)
        var errors = 0, total = 0
        for r in rows {
            let backend = ParakeetBackend(model: model)
            _ = try await backend.start(locale: Locale(identifier: "en"))
            backend.append(samples: try VoiceAudioConverter.readFile(dir.appendingPathComponent("\(r[0]).flac")))
            let f = try await backend.finish()
            let ref = WER.words(r[1])
            errors += WER.errors(ref, WER.words(f.text))
            total += ref.count
            #expect(f.engine == .parakeet && !f.segments.isEmpty)
        }
        let wer = Double(errors) / Double(total)
        print("ParakeetBackendTests WER \(String(format: "%.2f", wer * 100)) % over \(rows.count) utterances (\(total) words)")
        #expect(rows.count == 20 && wer <= 0.06, "NFR-V9 T1+: WER ≤ 6 %")
    }

    @Test(arguments: [true, false]) func livePartials(eou: Bool) async throws {
        VoiceEnvironment.lockDown()
        let eouDir = Self.models.appendingPathComponent("stt-eou")
        try #require(!eou || FileManager.default.fileExists(atPath: eouDir.path), "stt-eou is in the T1 dev set")
        let model = try await ParakeetModel.load(directory: Self.models.appendingPathComponent("stt"))
        let backend = ParakeetBackend(model: model, eou: eou ? try await ParakeetEOUModel.load(directory: eouDir) : nil)
        let stream = try await backend.start(locale: Locale(identifier: "en-US"))
        let partials = Mutex<[String]>([])
        let reader = Task { for await case .partial(let t) in stream { partials.withLock { $0.append(t) } } }
        let audio = try VoiceAudioConverter.readFile(VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation/q01.wav"))
        var at = 0
        while at < audio.count {  // real-time pace, 20 ms frames
            let n = min(320, audio.count - at)
            backend.append(samples: Array(audio[at..<(at + n)]))
            at += n
            if at % 3_200 == 0 { try await Task.sleep(for: .milliseconds(200)) }
        }
        try await Task.sleep(for: .milliseconds(600))
        let final = try await backend.finish()
        await reader.value
        let ps = partials.withLock { $0 }
        let ref = try String(contentsOf: VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation/q01.txt"), encoding: .utf8)
        print("livePartials eou=\(eou): \(ps.count) partials; last “\(ps.last ?? "")”; final “\(final.text)”")
        #expect(ps.count >= 3, "partials stream while recording")
        #expect(Double(WER.errors(WER.words(ref), WER.words(final.text))) / Double(WER.words(ref).count) <= 0.15)
    }

    /// The 30 s monologue at real-time pace: commits at its pauses, so the final pass only covers the tail; the joined
    /// final matches a one-shot pass over the whole buffer.
    @Test func monologueCommitsAtPausesAndMatchesTheBatchPass() async throws {
        VoiceEnvironment.lockDown()
        let model = try await ParakeetModel.load(directory: Self.models.appendingPathComponent("stt"))
        let audio = try VoiceAudioConverter.readFile(VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation/monologue-30s.wav"))
        let backend = ParakeetBackend(model: model)
        _ = try await backend.start(locale: Locale(identifier: "en"))
        var at = 0
        while at < audio.count {
            let n = min(3_200, audio.count - at)
            backend.append(samples: Array(audio[at..<(at + n)]))
            at += n
            try await Task.sleep(for: .milliseconds(200))
        }
        let t0 = ContinuousClock.now
        let final = try await backend.finish()
        let stopToFinal = ContinuousClock.now - t0
        let batch = try await model.transcribe(audio)
        let wer = Double(WER.errors(WER.words(batch.text), WER.words(final.text))) / Double(WER.words(batch.text).count)
        print("monologue: stop → final \(stopToFinal); vs batch WER \(String(format: "%.2f", wer * 100)) %; final “\(final.text)”")
        #expect(wer <= 0.03, "joining committed parts keeps the words of the one-shot pass")
        #expect(final.segments.last.map { $0.end > 25 } == true, "segment times are absolute")
    }
}
