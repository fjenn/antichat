// M3.T03 step 7 (R-050 AC4): a finished dictation's audio as 16 kHz mono AAC `.m4a`, written by the helper to the
// file the app named in `DictationStart.recordingURL` (the app then files it under `Media/<yyyy>/<sha256>.m4a`
// through `file_blob`, origin `recording`). Incognito dictations name no file, so nothing is written (contract 3).
@preconcurrency import AVFoundation
import Foundation

public enum RecordingWriter {
    public static func writeM4A(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: VoiceAudioFormat.sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_000
        var at = 0
        while at < samples.count {
            let n = min(chunk, samples.count - at)
            guard let b = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.pcm, frameCapacity: AVAudioFrameCount(n)) else { break }
            b.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + at, count: n) }
            try file.write(from: b)
            at += n
        }
    }
}
