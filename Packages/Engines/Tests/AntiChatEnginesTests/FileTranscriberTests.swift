// M3.T06 (R-056, AT-056 AC1): FileTranscriber. Unit tests use model doubles (progress monotonic 0 → 100, timestamps
// increasing, window ownership with 2 s overlap, line grouping, scratch file removed); `FileTranscriberRealTests`
// (@realModels) runs the five formats of fixtures/audio/formats through the real Parakeet (`stt`) and the 3 h FLAC
// (`ANTICHAT_LONG3H=<path>`, tools/fixtures/make-long-audio.sh) when given:
//   ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=… gpu-run.sh shared -- make test-unit FILTER=FileTranscriberRealTests
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

/// A recognizer that answers per window: one segment at 1 s and one at 27 s of every window.
final class WindowRecognizer: MultilingualRecognizer, @unchecked Sendable {
    let calls = Mutex(0)
    func transcribe(_ samples: [Float], language: String?) async throws -> WhisperKitModel.Result {
        let i = calls.withLock { c -> Int in c += 1; return c }
        let segs = [TranscriptSegment(start: 1, end: 3, text: "w\(i)a"), TranscriptSegment(start: 27, end: 29.5, text: "w\(i)b")]
        return WhisperKitModel.Result(text: segs.map(\.text).joined(separator: " "), language: language ?? "ja", segments: segs)
    }
    func detectLanguage(_ samples: [Float]) async throws -> (language: String, probability: Float) { ("ja", 0.99) }
}

struct FileTranscriberTests {
    static func wav(_ seconds: Double) throws -> URL {
        let u = VoiceTestAudio.tempDir("ft").appendingPathComponent("in.wav")
        try VoiceTestAudio.tone(u, seconds: seconds)
        return u
    }

    static func parakeetDouble(progressSteps: Int = 5) -> FileTranscriber.Engines {
        FileTranscriber.Engines(
            parakeetFile: { url, p in
                for i in 0...progressSteps { p(Double(i) / Double(progressSteps)) }  // FluidAudio reports 0 too
                let words = (0..<12).map { TranscriptSegment(start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, text: $0 == 5 ? "end." : "w\($0)") }
                return ParakeetModel.Result(text: words.map(\.text).joined(separator: " "), segments: words)
            },
            parakeet: { _ in ParakeetModel.Result(text: "this is an english sentence for the router", segments: []) },
            whisper: nil)
    }

    @Test func parakeetPathProgressIsMonotonicAndTimestamped() async throws {
        let url = try Self.wav(20)
        let seen = Mutex<[Double]>([])
        let scratch = VoiceTestAudio.tempDir("ft-scratch")
        let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url, locale: "en"), engines: Self.parakeetDouble(),
                                                     scratchDir: scratch) { p in seen.withLock { $0.append(p) } }
        let ps = seen.withLock { $0 }
        #expect(ps.first == 0 && ps.last == 100)
        #expect(zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 }, "monotonic: \(ps)")
        #expect(f.engine == .parakeet)
        let lines = f.text.split(separator: "\n")
        #expect(lines.allSatisfy { $0.range(of: #"^\[\d\d:\d\d:\d\d\] \S"#, options: .regularExpression) != nil }, "\(f.text)")
        #expect(zip(f.segments, f.segments.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "scratch file removed")
    }

    @Test func whisperWindowsOverlapTwoSecondsAndOwnEachSegmentOnce() async throws {
        let url = try Self.wav(75)  // windows at 0, 28, 56 s
        var e = Self.parakeetDouble()
        let rec = WindowRecognizer()
        e.whisper = { (rec, {}) }
        let seen = Mutex<[Double]>([])
        let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url, locale: "ja"), engines: e,
                                                     scratchDir: VoiceTestAudio.tempDir("ft-w")) { p in seen.withLock { $0.append(p) } }
        #expect(f.engine == .whisperkit && f.language == "ja")
        #expect(rec.calls.withLock { $0 } == 3)
        // Window k covers [28k, 28k + 30]; it owns segment starts in [28k + 1, 28k + 29) (all for the last window).
        #expect(f.segments.map(\.text) == ["w1a", "w1b", "w2a", "w2b", "w3a", "w3b"])
        #expect(f.segments.map(\.start) == [1, 27, 29, 55, 57, 83])
        let ps = seen.withLock { $0 }
        #expect(zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 } && ps.last == 100)
    }

    @Test func fixedOtherLanguageWithoutSttMultiIsUnavailable() async throws {
        let url = try Self.wav(2)
        await #expect(throws: Error.self) {
            _ = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url, locale: "ja"), engines: Self.parakeetDouble(),
                                                     scratchDir: VoiceTestAudio.tempDir("ft-u")) { _ in }
        }
    }

    @Test func autoRoutesNonParakeetLanguageToWhisper() async throws {
        let url = try Self.wav(10)
        var e = Self.parakeetDouble()
        e.parakeet = { _ in ParakeetModel.Result(text: "コンニチハ セカイ", segments: []) }
        let rec = WindowRecognizer()
        e.whisper = { (rec, {}) }
        let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url), engines: e,
                                                     scratchDir: VoiceTestAudio.tempDir("ft-a")) { _ in }
        #expect(f.engine == .whisperkit && f.language == "ja")
    }

    @Test func linesBreakAtPausesAndSentenceEnds() {
        let w = [TranscriptSegment(start: 0, end: 0.4, text: "Hello"), TranscriptSegment(start: 0.5, end: 0.9, text: "there."),
                 TranscriptSegment(start: 2.0, end: 2.4, text: "Next"), TranscriptSegment(start: 2.5, end: 3, text: "line")]
        let l = FileTranscriber.lines(words: w, duration: 3)
        #expect(l.map(\.text) == ["Hello there.", "Next line"])
        #expect(FileTranscriber.render(l) == "[00:00:00] Hello there.\n[00:00:02] Next line")
        #expect(FileTranscriber.stamp(3725.9) == "[01:02:05]")
    }

    @Test func resampleStreamsToSixteenKilohertzMono() throws {
        let src = VoiceTestAudio.tempDir("ft-r").appendingPathComponent("s.wav")
        try writeWAV([Float](repeating: 0.1, count: 44_100 * 2), sampleRate: 44_100, to: src)
        let out = src.deletingLastPathComponent().appendingPathComponent("o.wav")
        let n = try FileTranscriber.resample(src, to: out)
        #expect(abs(n - 32_000) < 400, "\(n)")
        #expect(try FileTranscriber.read(out, start: 16_000, count: 100).count == 100)
    }
}

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct FileTranscriberRealTests {
    static let out: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let d = root.appendingPathComponent("build/at/AT-056")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func engines() async throws -> FileTranscriber.Engines {
        VoiceEnvironment.lockDown()
        let models = ParakeetBackendTests.models
        let parakeet = try await ParakeetModel.load(directory: models.appendingPathComponent("stt"))
        return FileTranscriber.Engines(parakeetFile: { try await parakeet.transcribeFile($0, progress: $1) },
                                       parakeet: { try await parakeet.transcribe($0) }, whisper: nil)
    }

    @Test func fiveFormatsTranscribeWithTimestamps() async throws {
        let engines = try await Self.engines()
        let dir = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/formats")
        let ref = try String(contentsOf: dir.appendingPathComponent("clip.txt"), encoding: .utf8)
            .split(separator: "\n").map { String($0.dropFirst(11)) }.joined(separator: " ")
        var report: [[String: Any]] = []
        for ext in ["wav", "mp3", "m4a", "aac", "flac"] {
            let seen = Mutex<[Double]>([])
            let t0 = ContinuousClock.now
            let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: dir.appendingPathComponent("clip.\(ext)"), locale: "en"),
                                                         engines: engines, scratchDir: VoiceTestAudio.tempDir("ftr")) { p in
                seen.withLock { $0.append(p) }
            }
            let secs = Double((ContinuousClock.now - t0).components.attoseconds) / 1e18 + Double((ContinuousClock.now - t0).components.seconds)
            let ps = seen.withLock { $0 }
            let wer = WordErrorRate.wer(ref: ref, hyp: f.segments.map(\.text).joined(separator: " "))
            #expect(ps.first == 0 && ps.last == 100 && zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 }, "\(ext): \(ps)")
            #expect(f.segments.count >= 8, "\(ext): \(f.segments.count) lines")
            #expect(zip(f.segments, f.segments.dropFirst()).allSatisfy { $0.start < $1.start }, "\(ext)")
            #expect((f.segments.last?.start ?? 0) > 100, "\(ext): the last line is near the end of the 2-min clip")
            #expect(wer < 0.06, "\(ext): WER \(wer)")
            report.append(["format": ext, "lines": f.segments.count, "wer": wer, "progress_events": ps.count, "seconds": secs,
                           "head": Array(f.text.split(separator: "\n").prefix(3)).map(String.init)])
        }
        try JSONSerialization.data(withJSONObject: ["formats": report], options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.out.appendingPathComponent("formats.json"))
    }

    /// AT-NFR-V11 (make perf METRIC=V11): the 60-min file, 3 runs (A-M3-03); run under `gpu-run.sh timing`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_V11"] == "1"))
    func v11SixtyMinutes() async throws {
        let engines = try await Self.engines()
        let url = VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/long-file/long-60min.wav")
        var runs: [[String: Any]] = []
        var first = ""
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url, locale: "en"), engines: engines,
                                                         scratchDir: VoiceTestAudio.tempDir("v11")) { _ in }
            let d = ContinuousClock.now - t0
            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let audio = 3597.265
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            runs.append(["seconds": secs, "audio_s": audio, "realtime_x": audio / secs, "lines": f.segments.count, "load": load[0]])
            if first.isEmpty { first = f.text }
        }
        let ref = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            .split(separator: "\n").map { String($0.dropFirst(11)) }.joined(separator: " ")
        let hyp = first.split(separator: "\n").map { String($0.dropFirst(11)) }.joined(separator: " ")
        let wer = WordErrorRate.wer(ref: ref, hyp: hyp)
        try JSONSerialization.data(withJSONObject: ["runs": runs, "wer": wer, "file": "audio/long-file/long-60min.wav"],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: Self.out.appendingPathComponent("v11.json"))
        #expect(wer < 0.06, "60-min WER \(wer)")
    }

    /// AT-056 AC1 `testLong3h`: the generated 3 h FLAC (≤ 512 MB) completes; the first 50 lines go to the artefact.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_LONG3H"] != nil))
    func testLong3h() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_LONG3H"]!)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size <= 512 * 1024 * 1024)
        let engines = try await Self.engines()
        let seen = Mutex<[Double]>([])
        let t0 = ContinuousClock.now
        let f = try await FileTranscriber.transcribe(TranscribeFile(fileURL: url, locale: "en"), engines: engines,
                                                     scratchDir: VoiceTestAudio.tempDir("ft3h")) { p in seen.withLock { $0.append(p) } }
        let secs = Double((ContinuousClock.now - t0).components.seconds)
        let ps = seen.withLock { $0 }
        #expect(ps.last == 100 && zip(ps, ps.dropFirst()).allSatisfy { $0 < $1 })
        #expect((f.segments.last?.start ?? 0) > 3 * 3600 - 120)
        let head = f.text.split(separator: "\n").prefix(50).joined(separator: "\n")
        try (head + "\n").write(to: Self.out.appendingPathComponent("long-3h-head.txt"), atomically: true, encoding: .utf8)
        let summary: [String: Any] = ["file": url.lastPathComponent, "bytes": size, "lines": f.segments.count, "seconds": secs,
                                      "realtime_x": 3 * 3600 / max(1, secs), "progress_events": ps.count]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.out.appendingPathComponent("long-3h.json"))
    }
}

/// Plain WER (lowercase, punctuation stripped) for the format-matrix sanity check.
enum WordErrorRate {
    static func words(_ s: String) -> [String] {
        s.lowercased().unicodeScalars.map { CharacterSet.letters.union(.decimalDigits).contains($0) || $0 == "'" ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }.split(separator: " ").map { $0.replacingOccurrences(of: "'", with: "") }
    }

    static func wer(ref: String, hyp: String) -> Double {
        let r = words(ref), h = words(hyp)
        var prev = Array(0...h.count)
        for (i, rw) in r.enumerated() {
            var cur = [i + 1] + [Int](repeating: 0, count: h.count)
            for (j, hw) in h.enumerated() { cur[j + 1] = min(prev[j] + (rw == hw ? 0 : 1), prev[j + 1] + 1, cur[j] + 1) }
            prev = cur
        }
        return Double(prev[h.count]) / Double(max(1, r.count))
    }
}
