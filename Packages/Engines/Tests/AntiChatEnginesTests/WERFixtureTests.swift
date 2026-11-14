// M3.T05 step 4 (@realModels; AT-284 accuracy leg, NFR-V9): the routed recogniser on real speech — en (LibriSpeech
// test-clean, first 40 by id) and de / ja / zh / ar (FLEURS, 40 each), once with the spoken-language setting `auto`
// and once with the language fixed. Writes build/at/AT-284/wer.json rows {id, lang, mode, engine, language, ref, hyp};
// `python3 -I tools/voice/wer.py --in build/at/AT-284/wer.json --budget NFR-V9 --tier T1` scores them (CER for ja/zh).
// Models from the dev store (`stt`, `stt-multi`); offline (D-11).
//   ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=… gpu-run.sh shared -- make test-unit FILTER=WERFixtureTests
//   (ANTICHAT_WER_N=<n> per language, default 40)
import AntiChatEngineProtocol
import Foundation
import Testing

@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct WERFixtureTests {
    static let n = Int(ProcessInfo.processInfo.environment["ANTICHAT_WER_N"] ?? "") ?? 40

    struct Item { var id: String; var lang: String; var wav: URL; var ref: String }

    static func items() throws -> [Item] {
        let root = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio")
        var out: [Item] = []
        let ls = root.appendingPathComponent("librispeech-test-clean-200")
        let tsv = try String(contentsOf: ls.appendingPathComponent("transcripts.tsv"), encoding: .utf8)
        var en: [(String, String)] = []
        for line in tsv.split(separator: "\n") {
            let c = line.split(separator: "\t").map(String.init)
            if c.count == 3, c[0] != "id" { en.append((c[0], c[2])) }
        }
        for (id, text) in en.sorted(by: { $0.0 < $1.0 }).prefix(n) {
            out.append(Item(id: id, lang: "en", wav: ls.appendingPathComponent("\(id).flac"), ref: text))
        }
        for lang in ["de", "ja", "zh", "ar"] {
            let dir = root.appendingPathComponent("fleurs-multi/\(lang)")
            let wavs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.sorted().prefix(n)
            for w in wavs {
                let txt = dir.appendingPathComponent(w.replacingOccurrences(of: ".wav", with: ".txt"))
                out.append(Item(id: "\(lang)/\(w)", lang: lang, wav: dir.appendingPathComponent(w),
                                ref: try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return out
    }

    @Test func routedAccuracyPerLanguage() async throws {
        VoiceEnvironment.lockDown()
        let models = ParakeetBackendTests.models
        let parakeet = try await ParakeetModel.load(directory: models.appendingPathComponent("stt"))
        let whisper = try await WhisperKitModel.load(directory: models.appendingPathComponent("stt-multi"))
        var rows: [[String: String]] = []
        let t0 = ContinuousClock.now
        for item in try Self.items() {
            let audio = try VoiceAudioConverter.readFile(item.wav)
            for mode in ["auto", "fixed"] {
                let b = RoutedBackend(parakeet: ParakeetBackend(model: parakeet), whisper: { (whisper, {}) },
                                      setting: mode == "auto" ? nil : item.lang)
                _ = try await b.start(locale: nil)
                b.append(samples: audio)
                let f = try await b.finish()
                rows.append(["id": item.id, "lang": item.lang, "mode": mode, "engine": f.engine.rawValue, "language": f.language,
                             "ref": item.ref, "hyp": f.text])
            }
        }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/at/AT-284/wer.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc: [String: Any] = ["rows": rows, "n_per_language": Self.n, "models": ["stt", "stt-multi"],
                                  "seconds": Double((ContinuousClock.now - t0).components.seconds)]
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        // Routing: in auto, ja / zh / ar go to WhisperKit, en / de stay on Parakeet.
        for lang in ["ja", "zh", "ar"] {
            let auto = rows.filter { $0["lang"] == lang && $0["mode"] == "auto" }
            #expect(auto.allSatisfy { $0["engine"] == "whisperkit" }, "\(lang): \(auto.filter { $0["engine"] != "whisperkit" }.count) not re-run")
        }
        for lang in ["en", "de"] {
            let auto = rows.filter { $0["lang"] == lang && $0["mode"] == "auto" }
            #expect(auto.filter { $0["engine"] == "parakeet" }.count >= auto.count * 9 / 10, "\(lang) mostly on Parakeet")
        }
    }
}
