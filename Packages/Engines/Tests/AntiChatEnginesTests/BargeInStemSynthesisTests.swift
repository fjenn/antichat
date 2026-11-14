// M3.T15 step 4 (fallback named in the task: "synthesise in a @realModels test that writes the WAVs";
// antichat-bench talks to the helper only and never links AntiChatEngines). Writes the Kokoro `tts` stems of
// `fixtures/audio/barge-in/` from `tools/fixtures/barge-in-texts.txt`: one 24 kHz mono 16-bit WAV per line,
// `ttsNN.wav`, voice af_heart (FluidAudio KokoroAneManager on the ANE; offline, D-11). Run by
// `tools/fixtures/make-voice-fixtures.py barge-in` with ANTICHAT_SYNTH_TEXTS / ANTICHAT_SYNTH_OUT set.
import Foundation
import Testing

@testable import AntiChatEngines

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_SYNTH_OUT"] != nil))
struct BargeInStemSynthesisTests {
    @Test func synthesizeBargeInStems() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["ANTICHAT_SYNTH_OUT"]!)
        let texts = try String(contentsOfFile: env["ANTICHAT_SYNTH_TEXTS"] ?? "tools/fixtures/barge-in-texts.txt", encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let models = env["ANTICHAT_MODELS"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
        VoiceEnvironment.lockDown()
        let tts = try await KokoroTTS.load(
            ttsDirectory: models.appendingPathComponent("tts"),
            linkRoot: FileManager.default.temporaryDirectory.appendingPathComponent("antichat-synth-\(getpid())"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (i, t) in texts.enumerated() {
            let a = try await tts.synthesize(t)
            #expect(a.samples.count > a.sampleRate)  // > 1 s of speech
            try Self.writeWAV(a.samples, rate: a.sampleRate, to: out.appendingPathComponent(String(format: "tts%02d.wav", i + 1)))
        }
    }

    static func writeWAV(_ x: [Float], rate: Int, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in x { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try d.write(to: url)
    }
}
