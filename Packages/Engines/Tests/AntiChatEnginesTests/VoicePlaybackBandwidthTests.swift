// 0.0.8 "old radio" regression: a live conversation's reply plays through `PlainPlaybackDevice` (a plain engine, no
// voice processing), not the VPIO capture graph, and comes out full band. Offline: the device's engine runs in
// manual rendering mode, so nothing reaches the speakers and no microphone is opened.
//   swift test --filter VoicePlaybackBandwidthTests
@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct VoicePlaybackBandwidthTests {
    static let renderRate = 48_000.0

    static func offlineDevice() throws -> PlainPlaybackDevice {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: renderRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        return PlainPlaybackDevice(sampleRate: 24_000, engine: engine)
    }

    /// Renders `seconds` of the device's output (left channel).
    static func render(_ device: PlainPlaybackDevice, seconds: Double) throws -> [Float] {
        let engine = device.engine
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var out: [Float] = []
        while out.count < Int(seconds * renderRate) {
            let status = try engine.renderOffline(4_096, to: buffer)
            #expect(status == .success)
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return out
    }

    /// Mean power spectral density (per Hz) in [lo, hi) relative to 300 Hz – 4 kHz, in dB (Hann, 4096-point FFT).
    static func bandDB(_ x: [Float], rate: Double, lo: Double, hi: Double) -> Double {
        let n = 4_096
        let log2n = vDSP_Length(12)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var ref = 0.0, band = 0.0
        var i = 0
        while i + n <= x.count {
            var seg = Array(x[i..<i + n])
            vDSP_vmul(seg, 1, window, 1, &seg, 1, vDSP_Length(n))
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    seg.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for k in 1..<n / 2 {
                let f = Double(k) * rate / Double(n)
                let p = Double(re[k] * re[k] + im[k] * im[k])
                if f >= 300, f < 4_000 { ref += p }
                if f >= lo, f < hi { band += p }
            }
            i += n
        }
        return 10 * log10((band / (hi - lo)) / (ref / 3_700))
    }

    /// White noise at the TTS rate: flat up to 12 kHz (Nyquist of 24 kHz).
    static func noise(seconds: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 24_000)).map { _ in Float.random(in: -0.25...0.25, using: &g) }
    }

    @Test func voiceModePlaybackGoesThroughThePlainEngineAtFullBand() throws {
        let device = try Self.offlineDevice()
        // A live conversation's audio graph (no injected input) with this output: capture is never started here.
        let audio = VoiceAudioEngine(injected: nil, enableAEC: false, playback: device)
        #expect(audio.playback === device, "the reply's output is the plain device, not the capture graph")
        #expect(!device.engine.outputNode.isVoiceProcessingEnabled, "no voice processing on the reply's engine")

        let source = Self.noise(seconds: 1.5)
        // As `DuplexOutputSink` hands it over: 100 ms slices.
        for start in stride(from: 0, to: source.count, by: 2_400) {
            let ok = audio.schedulePlayback(Array(source[start..<min(start + 2_400, source.count)]))
            #expect(ok)
        }
        let out = try Self.render(device, seconds: 1.4)
        let body = Array(out[Int(0.1 * Self.renderRate)...])
        let rms = sqrt(body.reduce(0) { $0 + $1 * $1 } / Float(body.count))
        #expect(rms > 0.05, "the reply is audible in the render (rms \(rms))")
        // Full band: 6–8 kHz and 8–11 kHz carry the same density as the speech band (a voice-call path cuts them).
        let mid = Self.bandDB(body, rate: Self.renderRate, lo: 6_000, hi: 8_000)
        let high = Self.bandDB(body, rate: Self.renderRate, lo: 8_000, hi: 11_000)
        #expect(abs(mid) < 3, "6–8 kHz at \(mid) dB of the speech band")
        #expect(abs(high) < 3, "8–11 kHz at \(high) dB of the speech band")
        print("VoicePlaybackBandwidth: rms \(rms), 6–8 kHz \(mid) dB, 8–11 kHz \(high) dB (re 0.3–4 kHz)")
        // (`.dataPlayedBack` callbacks need a real output clock: they do not fire in manual rendering.)
        audio.flushPlayback()
        audio.stop()
    }

    @Test func aFlushedBufferIsNeverReportedPlayedAndPlaybackResumesAfterIt() async throws {
        let device = try Self.offlineDevice()
        let played = Mutex(0)
        #expect(device.schedulePlayback(Self.noise(seconds: 0.5)) { played.withLock { $0 += 1 } })
        device.flushPlayback()
        _ = try Self.render(device, seconds: 0.3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(played.withLock { $0 } == 0)
        #expect(device.schedulePlayback(Self.noise(seconds: 0.3)) { played.withLock { $0 += 1 } })
        let out = try Self.render(device, seconds: 0.25)
        #expect(out.contains { abs($0) > 0.01 }, "the next reply plays after a flush")
        device.stop()
    }
}
