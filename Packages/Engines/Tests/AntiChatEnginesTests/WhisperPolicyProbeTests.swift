// AT-284 diagnostics (@realModels): WhisperKit alone on the FLEURS ja / zh / ar fixtures with the language fixed, once
// per `WhisperDecodePolicy` variant, so each hallucination control is measured on its own. Writes
// build/at/AT-284/probe-<variant>.json (wer.py rows, mode = variant); score with
//   python3 -I tools/voice/wer.py --in build/at/AT-284/probe-<variant>.json --mode <variant>
//   ANTICHAT_VOICE_IT=1 ANTICHAT_WHISPER_PROBE=legacy,standard,… gpu-run.sh shared -- make test-unit FILTER=WhisperPolicyProbeTests
import AntiChatEngineProtocol
import Foundation
import Testing

@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"
                    && ProcessInfo.processInfo.environment["ANTICHAT_WHISPER_PROBE"] != nil && VoiceTestAudio.fixturesRoot != nil))
struct WhisperPolicyProbeTests {
    static let variants: [String: WhisperDecodePolicy] = {
        var v: [String: WhisperDecodePolicy] = ["legacy": .legacy, "standard": .standard]
        var s = WhisperDecodePolicy.standard
        s.trimSilence = false
        v["notrim"] = s
        s = .standard
        s.normalizeLevel = false
        v["nonorm"] = s
        s = .standard
        s.wordTimestamps = true
        v["words"] = s
        s = .standard
        s.rescueEmptyDecode = false  // M9.T05: the empty-decode rescue on its own (ar/28)
        v["norescue"] = s
        return v
    }()

    @Test func policyVariants() async throws {
        VoiceEnvironment.lockDown()
        let names = (ProcessInfo.processInfo.environment["ANTICHAT_WHISPER_PROBE"] ?? "").split(separator: ",").map(String.init)
        let langs = (ProcessInfo.processInfo.environment["ANTICHAT_WER_LANGS"] ?? "ja,zh,ar").split(separator: ",").map(String.init)
        let whisper = try await WhisperKitModel.load(directory: ParakeetBackendTests.models.appendingPathComponent("stt-multi"))
        let items = try WERFixtureTests.items().filter { langs.contains($0.lang) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in names {
            let policy = try #require(Self.variants[name], "unknown variant \(name)")
            await whisper.setPolicy(policy)
            var rows: [[String: Any]] = []
            let t0 = ContinuousClock.now
            for item in items {
                let audio = try VoiceAudioConverter.readFile(item.wav)
                let r = try await whisper.transcribe(audio, language: item.lang)
                var row: [String: Any] = ["id": item.id, "lang": item.lang, "mode": name, "engine": "whisperkit", "language": r.language,
                                          "ref": item.ref, "hyp": r.text, "voiced_end": r.voicedEnd, "dur": Double(audio.count) / 16_000,
                                          "segments": r.segments.map { ["s": $0.start, "e": $0.end, "t": $0.text] }]
                if !r.words.isEmpty { row["words"] = r.words.map { ["w": $0.word, "s": $0.start, "e": $0.end, "p": $0.probability] } }
                rows.append(row)
            }
            let out = root.appendingPathComponent("build/at/AT-284/probe-\(name).json")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let doc: [String: Any] = ["rows": rows, "variant": name, "seconds": Double((ContinuousClock.now - t0).components.seconds)]
            try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        }
    }
}

/// AT-284 diagnostics: Parakeet's confidence and the NL language guess per fixture utterance (the auto-route keep rule).
///   ANTICHAT_VOICE_IT=1 ANTICHAT_PARAKEET_CONF=1 gpu-run.sh shared -- make test-unit FILTER=ParakeetConfidenceProbeTests
@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"
                    && ProcessInfo.processInfo.environment["ANTICHAT_PARAKEET_CONF"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct ParakeetConfidenceProbeTests {
    @Test func confidences() async throws {
        VoiceEnvironment.lockDown()
        let parakeet = try await ParakeetModel.load(directory: ParakeetBackendTests.models.appendingPathComponent("stt"))
        var rows: [[String: Any]] = []
        for item in try WERFixtureTests.items() {
            let r = try await parakeet.transcribe(try VoiceAudioConverter.readFile(item.wav))
            let d = LanguageRouter.dominant(r.text)
            rows.append(["id": item.id, "lang": item.lang, "confidence": r.confidence, "nl": d.language ?? "", "nl_p": d.probability,
                         "hyp": r.text])
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("build/at/AT-284/parakeet-confidence.json"))
    }
}

