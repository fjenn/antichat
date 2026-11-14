// M3.T01: the one PCM format every voice model consumes (16 kHz mono Float32: Parakeet, Silero, smart-turn,
// WhisperKit) and the converter from any capture / file format into it. TTS output keeps the model's own rate
// (Kokoro 24 kHz) and is not converted here.
@preconcurrency import AVFoundation
import Foundation

public enum VoiceAudioFormat {
    public static let sampleRate: Double = 16_000
    /// 20 ms frames on the wire / in the capture tap (320 samples).
    public static let frameSamples = 320

    /// Non-interleaved Float32 mono at 16 kHz.
    public static let pcm: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    public static func seconds(samples: Int) -> Double { Double(samples) / sampleRate }
}

/// Converts buffers of one source format to `VoiceAudioFormat.pcm` (stateful: keeps the resampler's history so
/// consecutive capture buffers join without clicks).
public final class VoiceAudioConverter: @unchecked Sendable {
    public let source: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(source: AVAudioFormat) {
        self.source = source
        converter = Self.isTarget(source) ? nil : AVAudioConverter(from: source, to: VoiceAudioFormat.pcm)
    }

    static func isTarget(_ f: AVAudioFormat) -> Bool {
        f.commonFormat == .pcmFormatFloat32 && f.sampleRate == VoiceAudioFormat.sampleRate && f.channelCount == 1
            && !f.isInterleaved
    }

    /// The samples of `buffer` at 16 kHz mono.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter else { return Self.samples(buffer) }
        let ratio = VoiceAudioFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.pcm, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return Self.samples(out)
    }

    static func samples(_ b: AVAudioPCMBuffer) -> [Float] {
        guard let ch = b.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength)))
    }

    /// Reads a whole audio file (any format AVFoundation opens) as 16 kHz mono samples.
    public static func readFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let conv = VoiceAudioConverter(source: monoFormat)
        var out: [Float] = []
        let chunk: AVAudioFrameCount = 32_768
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            out += try conv.convert(format.channelCount == 1 ? buf : downmix(buf))
        }
        return out
    }

    /// Averages the channels of a non-interleaved Float32 buffer into one.
    static func downmix(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false)!
        let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength)!
        out.frameLength = b.frameLength
        let n = Int(b.frameLength), c = Int(b.format.channelCount)
        guard let src = b.floatChannelData, let dst = out.floatChannelData else { return out }
        for i in 0..<n {
            var s: Float = 0
            for k in 0..<c { s += src[k][i] }
            dst[0][i] = s / Float(c)
        }
        return out
    }
}
