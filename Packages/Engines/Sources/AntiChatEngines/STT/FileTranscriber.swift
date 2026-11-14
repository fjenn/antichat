// M3.T06 step 2 (R-056; P-media-02): one audio file → a timestamped transcript, in the helper (contract 1).
//   1. The file (WAV / MP3 / M4A / AAC / FLAC) is converted to 16 kHz mono Float32 in the helper's scratch dir, a
//      32 k-frame chunk at a time (constant memory for a 3 h file); the scratch file is deleted afterwards.
//   2. Language route (M3.T05) on the first 30 s: the setting when fixed; auto = Parakeet's transcript of the first
//      30 s, then (unless it is clearly one of the user's Parakeet languages) WhisperKit's language detection.
//   3. Parakeet: FluidAudio `transcribeDiskBacked` (FluidAudio@b6a8b39 `AsrManager.swift:467`, memory-mapped,
//      seam-aware chunks, `ChunkProcessor.swift`) with its progress stream; WhisperKit: 30 s windows, 2 s overlap,
//      each window decoded with the hallucination controls of `WhisperDecodePolicy`.
//   4. Progress = processed seconds ÷ duration (0…100, monotonic, real); the result is `[hh:mm:ss] text` per line
//      (Parakeet words grouped at pauses ≥ 0.8 s, sentence ends after ≥ 4 s or 20 s; Whisper's own segments).
// Not a GPU job: Parakeet runs on the ANE, WhisperKit on its Core ML default units (K-NEW-ENG-10). Runs beside a live
// dictation (each holds its own lease; the scheduler arbitrates residency) instead of cancel-and-resume (A-M3-T06a).
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public enum FileTranscriber {
    public static let sampleRate = 16_000
    public static let window = 30 * 16_000
    public static let overlap = 2 * 16_000
    public typealias WhisperLease = @Sendable () async throws -> (any MultilingualRecognizer, @Sendable () async -> Void)

    /// What a file transcription needs from the models (real Parakeet / WhisperKit, or test doubles).
    public struct Engines: Sendable {
        public var parakeetFile: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> ParakeetModel.Result
        public var parakeet: @Sendable ([Float]) async throws -> ParakeetModel.Result
        /// nil = `stt-multi` is not installed (auto keeps Parakeet; a fixed other language is `voice.unavailable`).
        public var whisper: WhisperLease?

        public init(parakeetFile: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> ParakeetModel.Result,
                    parakeet: @escaping @Sendable ([Float]) async throws -> ParakeetModel.Result,
                    whisper: WhisperLease?) {
            self.parakeetFile = parakeetFile
            self.parakeet = parakeet
            self.whisper = whisper
        }
    }

    /// Converts `url` to 16 kHz mono Float32 WAV at `scratch` (streamed). Returns the frame count.
    @discardableResult
    public static func resample(_ url: URL, to scratch: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let conv = VoiceAudioConverter(source: mono)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        let out = try AVAudioFile(forWriting: scratch, settings: outFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames = 0
        let chunk: AVAudioFrameCount = 32_768
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            let samples = try conv.convert(format.channelCount == 1 ? buf : VoiceAudioConverter.downmix(buf))
            guard !samples.isEmpty, let ob = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            ob.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ob.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try out.write(from: ob)
            frames += samples.count
        }
        return frames
    }

    /// `count` samples from frame `start` of a 16 kHz mono Float32 file.
    static func read(_ url: URL, start: Int, count: Int) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard start < f.length else { return [] }
        f.framePosition = AVAudioFramePosition(start)
        let n = AVAudioFrameCount(min(Int64(count), f.length - Int64(start)))
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { return [] }
        try f.read(into: b, frameCount: n)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    /// The whole run. `progress` gets 0…100, monotonic.
    public static func transcribe(_ request: TranscribeFile, engines: Engines, scratchDir: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> FinalTranscript {
        let fm = FileManager.default
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let scratch = scratchDir.appendingPathComponent("transcribe-\(request.requestID.uuidString).wav")
        defer { try? fm.removeItem(at: scratch) }
        let last = Mutex<Double?>(nil)
        let report: @Sendable (Double) -> Void = { p in
            let v = min(100, max(0, p))
            let send = last.withLock { l -> Bool in
                guard l.map({ v > $0 }) ?? true else { return false }  // strictly increasing, 0 once
                l = v
                return true
            }
            if send { progress(v) }
        }
        report(0)
        let total = try resample(request.fileURL, to: scratch)
        try Task.checkCancellation()
        guard total >= sampleRate / 4 else {
            report(100)
            return FinalTranscript(text: "", language: LanguageRouter.base(request.locale) ?? "", engine: .parakeet)
        }
        // Route on the first 30 s.
        var language = LanguageRouter.base(request.locale)
        var useWhisper = false
        switch LanguageRouter.route(setting: request.locale) {
        case .whisper(let l):
            guard engines.whisper != nil else { throw AntiChatError.voice("unavailable", "stt-multi (other languages) is not installed") }
            useWhisper = true
            language = l
        case .parakeet: break
        case .auto:
            let head = try read(scratch, start: 0, count: window)
            let first = try await engines.parakeet(head)
            if let lease = engines.whisper, !LanguageRouter.keepsParakeet(first.text, confidence: first.confidence), !TranscriptText.isNonSpeech(first.text) {
                let (model, release) = try await lease()
                let detected = try await model.detectLanguage(head)
                await release()
                if LanguageRouter.needsWhisper(detected: detected.language) {
                    useWhisper = true
                    language = detected.language
                } else {
                    language = detected.language
                }
            } else {
                language = LanguageRouter.dominant(first.text).language
            }
        }
        try Task.checkCancellation()
        let duration = Double(total) / Double(sampleRate)
        if useWhisper, let lease = engines.whisper {
            let (model, release) = try await lease()
            do {
                let lines = try await whisperWindows(scratch, total: total, language: language, model: model, report: report)
                await release()
                report(100)
                return FinalTranscript(text: render(lines), language: language ?? "", engine: .whisperkit, segments: lines)
            } catch {
                await release()
                throw error
            }
        }
        let r = try await engines.parakeetFile(scratch) { fraction in report(fraction * 100) }
        report(100)
        let lines = lines(words: r.segments, duration: duration)
        return FinalTranscript(text: render(lines), language: language ?? "", engine: .parakeet, segments: lines)
    }

    /// WhisperKit over 30 s windows with 2 s overlap; a segment belongs to the window whose core (the part after the
    /// previous window's overlap midpoint) holds its start.
    static func whisperWindows(_ scratch: URL, total: Int, language: String?, model: any MultilingualRecognizer,
                               report: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        let step = window - overlap
        var out: [TranscriptSegment] = []
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let samples = try read(scratch, start: start, count: window)
            let t0 = Double(start) / Double(sampleRate)
            let isLast = start + window >= total
            let lo = start == 0 ? -Double.infinity : t0 + Double(overlap) / 2 / Double(sampleRate)
            let hi = isLast ? Double.infinity : t0 + Double(step + overlap / 2) / Double(sampleRate)
            let r = try await model.transcribe(samples, language: language)
            for s in r.segments where !s.text.isEmpty {
                let seg = TranscriptSegment(start: s.start + t0, end: s.end + t0, text: s.text)
                if seg.start >= lo, seg.start < hi { out.append(seg) }
            }
            report(Double(min(total, start + window)) / Double(total) * 100)
            start += step
        }
        return out
    }

    /// Parakeet word timings → transcript lines: a new line after a pause ≥ 0.8 s, at a sentence end once the line
    /// holds ≥ 4 s, or at 20 s.
    public static func lines(words: [TranscriptSegment], duration: Double) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for w in words {
            if var cur = out.last {
                let gap = w.start - cur.end
                let long = cur.end - cur.start
                let sentenceEnd = cur.text.last.map { ".?!。？！".contains($0) } ?? false
                if gap < 0.8, long < 20, !(sentenceEnd && long >= 4) {
                    cur.text += " " + w.text
                    cur.end = w.end
                    out[out.count - 1] = cur
                    continue
                }
            }
            out.append(TranscriptSegment(start: w.start, end: w.end, text: w.text))
        }
        return out
    }

    /// `[hh:mm:ss] text` per line.
    public static func render(_ lines: [TranscriptSegment]) -> String {
        lines.map { "\(stamp($0.start)) \($0.text.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    public static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "[%02d:%02d:%02d]", s / 3600, s / 60 % 60, s % 60)
    }
}
