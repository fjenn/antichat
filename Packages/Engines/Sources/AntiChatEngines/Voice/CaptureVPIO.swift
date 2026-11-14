// Audio I/O for the voice spike (M0.T05 steps 2–3, 7).
// - `LiveCapture`: real default microphone through the vendored speech-swift `FullDuplexAudioIO`
//   (one AVAudioEngine, Voice Processing I/O on → AEC; 16 kHz mono callback). Capture runs in the helper,
//   so the TCC prompt must name the responsible app ("AntiChat"), K-NEW-ARCH-5.
// - `PlaybackOut`: AVAudioEngine + AVAudioPlayerNode output. In `[IN-PIPELINE]` mode the V1 end point is
//   the moment the first PCM buffer is scheduled on this node (device/driver latency excluded).
@preconcurrency import AVFoundation
import Foundation
import SpeechSwiftVendored

public final class LiveCapture: @unchecked Sendable {
    private let io = FullDuplexAudioIO(configuration: .init(inputSampleRate: 16_000, outputSampleRate: 24_000, enableAEC: true))
    private let lock = NSLock()
    private var samples: [Float] = []
    private var callbacks = 0

    public init() {}

    public var microphoneName: String { io.microphoneName }

    /// Captures `seconds` of audio; returns the samples and the callback count.
    public func capture(seconds: Double) async throws -> (samples: [Float], callbacks: Int) {
        try io.start { [weak self] s in
            guard let self else { return }
            self.lock.lock()
            self.samples.append(contentsOf: s)
            self.callbacks += 1
            self.lock.unlock()
        }
        // Stop the microphone even when the sleep is cancelled.
        do { try await Task.sleep(for: .seconds(seconds)) } catch { io.stop(); throw error }
        io.stop()
        return lock.withLock { (samples, callbacks) }
    }
}

public func rmsDBFS(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return -.infinity }
    let ms = x.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(x.count)
    return ms > 0 ? 10 * log10(ms) : -.infinity
}

public final class PlaybackOut: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    public init() {
        engine.attach(player)
    }

    /// Connects the player for `sampleRate` mono and starts the engine.
    public func prepare(sampleRate: Int, volume: Float) throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        if format?.sampleRate != f.sampleRate {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: f)
            format = f
        }
        engine.mainMixerNode.outputVolume = volume
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying { player.play() }
    }

    /// Schedules one buffer; returns when it has been handed to the node.
    public func schedule(_ samples: [Float]) {
        guard let f = format, !samples.isEmpty,
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(b, completionHandler: nil)
    }

    /// Ends this turn's playback; the engine keeps running so the next turn's first buffer is a plain
    /// `scheduleBuffer` hand-off (engine start is not part of NFR-V2 "audio out").
    public func stopPlayer() {
        player.stop()
    }

    public func stop() {
        player.stop()
        engine.stop()
    }
}

/// 16-bit PCM WAV writer (inspection output only).
public func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let n = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(n)
    // Int16(NaN) traps; a NaN sample becomes silence.
    for s in samples { u16(UInt16(bitPattern: s.isNaN ? 0 : Int16(max(-1, min(1, s)) * 32767))) }
    try d.write(to: url)
}
