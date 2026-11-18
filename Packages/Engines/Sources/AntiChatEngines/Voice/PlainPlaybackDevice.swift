// 0.0.8 "old radio" fix: a live conversation's reply plays on its own plain `AVAudioEngine` (no voice processing; the
// input node is never touched, so this engine never opens a microphone), mono at the TTS rate into the main mixer,
// the same path as read aloud (`PlaybackOut`). Speech played into the VPIO graph sounded band-limited on the built-in
// speakers (owner report after 0.0.7). The device keeps `DuplexOutputSink`'s contract: a `.dataPlayedBack` callback
// per buffer (never for a flushed one), pause in place / resume / flush, volume = speaker mute, and a route change
// (the engine is stopped by the system) reports the queued audio as lost and restarts on the next buffer.
@preconcurrency import AVFoundation
import Foundation

public final class PlainPlaybackDevice: VoicePlaybackDevice, @unchecked Sendable {
    private let lock = NSLock()
    /// The output engine (tests pass one in manual rendering mode).
    let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var generation = 0
    private var paused = false
    private var observer: NSObjectProtocol?
    private var reset: (@Sendable () -> Void)?

    public init(sampleRate: Int = 24_000, engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.configurationChanged() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        player.stop()
        engine.stop()
    }

    public var onPlaybackReset: (@Sendable () -> Void)? {
        get { lock.withLock { reset } }
        set { lock.withLock { reset = newValue } }
    }

    @discardableResult
    public func schedulePlayback(_ samples: [Float], onPlayed: (@Sendable () -> Void)? = nil) -> Bool {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let (gen, isPaused) = lock.withLock { (generation, paused) }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.lock.withLock({ self.generation == gen }) else { return }
            onPlayed?()
        }
        if !isPaused, !player.isPlaying { player.play() }
        return true
    }

    public func pausePlayback() {
        lock.withLock { paused = true }
        player.pause()
    }

    public func resumePlayback() {
        lock.withLock { paused = false }
        if engine.isRunning { player.play() }
    }

    /// Drops every queued buffer (their callbacks are ignored) and silences the output now. `stop()` runs outside the
    /// lock: it can complete the flushed buffers' callbacks on this thread.
    public func flushPlayback() {
        lock.withLock {
            generation &+= 1
            paused = false
        }
        player.stop()
    }

    public func setPlaybackVolume(_ volume: Float) { player.volume = volume }

    /// Nothing is held back: every buffer is scheduled as it arrives.
    public func playPrebuffered() {}

    /// The session ended: the output device is released.
    public func stop() {
        lock.withLock {
            generation &+= 1
            paused = false
        }
        player.stop()
        engine.stop()
    }

    /// A route / device change stopped the engine: the queued audio is gone (the sink re-bases its clock).
    private func configurationChanged() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            generation &+= 1
            return reset
        }
        player.stop()
        callback?()
    }
}
