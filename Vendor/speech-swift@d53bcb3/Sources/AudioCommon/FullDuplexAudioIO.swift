#if canImport(AVFoundation)
import AVFoundation
import Foundation
import os

/// Microphone capture and scheduled low-latency playback on one audio engine.
///
/// Unlike ``StreamingAudioPlayer``, playback uses `AVAudioPlayerNode`. Apple's
/// Voice Processing I/O can therefore inspect scheduled output buffers and use
/// them as the acoustic-echo reference for a true full-duplex conversation.
public final class FullDuplexAudioIO: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var inputSampleRate: Int
        public var outputSampleRate: Int
        public var inputBufferFrames: UInt32
        public var playbackPrebufferFrames: Int
        public var enableAEC: Bool

        public init(
            inputSampleRate: Int = 16_000,
            outputSampleRate: Int = 22_050,
            inputBufferFrames: UInt32 = 1_024,
            playbackPrebufferFrames: Int = 3,
            enableAEC: Bool = true
        ) {
            self.inputSampleRate = inputSampleRate
            self.outputSampleRate = outputSampleRate
            self.inputBufferFrames = inputBufferFrames
            self.playbackPrebufferFrames = playbackPrebufferFrames
            self.enableAEC = enableAEC
        }

        public func validate() throws {
            guard inputSampleRate > 0 else {
                throw FullDuplexAudioError.invalidConfiguration(
                    "input sample rate must be positive")
            }
            guard outputSampleRate > 0 else {
                throw FullDuplexAudioError.invalidConfiguration(
                    "output sample rate must be positive")
            }
            guard inputBufferFrames > 0 else {
                throw FullDuplexAudioError.invalidConfiguration(
                    "input buffer size must be positive")
            }
            guard playbackPrebufferFrames > 0,
                  playbackPrebufferFrames <= 32 else {
                throw FullDuplexAudioError.invalidConfiguration(
                    "playback prebuffer must be between 1 and 32 frames")
            }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public let scheduledBuffers: Int
        public let completedBuffers: Int
        public let underruns: Int
        public let microphoneLevel: Float
    }

    public enum State: Sendable, Equatable {
        case stopped
        case running
        case failed(String)
    }

    public let configuration: Configuration
    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return audioState
    }

    public var microphoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
    }

    private let lock = NSLock()
    private let playbackQueue: DispatchQueue
    private let playbackQueueKey = DispatchSpecificKey<Void>()
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackSourceFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var playbackConverter: AVAudioConverter?
    private var audioState: State = .stopped
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var playbackPrebufferTarget = 0
    // ANTICHAT-PATCH: UP-SS-007 output-only pause / resume / flush and per-buffer played callbacks (M3.T10 barge-in)
    private var playbackStarted = false
    private var prebufferPlayed: [(@Sendable () -> Void)?] = []
    private var playbackPaused = false
    // ANTICHAT-PATCH-END
    // ANTICHAT-PATCH: UP-SS-008 VPIO other-audio ducking at the minimum level (M3.T12, R-280 AC3)
    /// Set before `start`: with AEC on, other apps' audio is ducked no more than the minimum system level.
    public var otherAudioDuckingMinimum = false
    /// The ducking configuration the running graph applied (nil: none; the test hook of `testDuckingSettingOff`).
    public private(set) var appliedDuckingLevel: String?
    // ANTICHAT-PATCH-END
    // ANTICHAT-PATCH: UP-SS-009 output volume and end-of-input prebuffer flush (M3 review P1-3, P1-4)
    private var outputVolume: Float = 1
    // ANTICHAT-PATCH-END
    private var playbackGeneration = 0
    private var stopping = false
    private var scheduledBuffers = 0
    private var completedBuffers = 0
    private var underruns = 0
    private var microphoneLevel: Float = 0

    private static let log = Logger(
        subsystem: "audio.soniqo", category: "FullDuplexAudioIO")

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let queue = DispatchQueue(
            label: "audio.soniqo.full-duplex-playback",
            qos: .userInteractive)
        self.playbackQueue = queue
        queue.setSpecific(key: playbackQueueKey, value: ())
    }

    static func recoveryPrebufferFrames(initial: Int) -> Int {
        min(32, max(8, initial * 2))
    }

    /// Start capture, resampled to `configuration.inputSampleRate`.
    ///
    /// The callback executes on Core Audio's capture thread. It should only
    /// copy/enqueue samples; model inference belongs on a separate worker.
    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        try configuration.validate()
        stop()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: configuration.enableAEC ? .voiceChat : .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let playerNode = AVAudioPlayerNode()

        do {
            try AudioIO.enableVoiceProcessingIfRequested(
                configuration.enableAEC
            ) { enabled in
                try inputNode.setVoiceProcessingEnabled(enabled)
            }
        } catch {
            setState(.failed(
                "Cannot enable acoustic echo cancellation: \(error.localizedDescription)"))
            throw error
        }
        // ANTICHAT-PATCH: UP-SS-008 VPIO other-audio ducking at the minimum level (M3.T12, R-280 AC3)
        appliedDuckingLevel = nil
        if configuration.enableAEC, otherAudioDuckingMinimum {
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
            appliedDuckingLevel = "min"
        }
        // ANTICHAT-PATCH-END

        // Capture can be configured immediately after Voice Processing is
        // enabled. Playback is attached only after `engine.start()` below:
        // on macOS the output-side Voice Processing format settles
        // asynchronously and a pre-start player connection can retain the
        // stale hardware rate, causing AUVP initialization to fail.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              hardwareFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardwareFormat.sampleRate,
                  channels: 1,
                  interleaved: false),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(configuration.inputSampleRate),
                  channels: 1,
                  interleaved: false),
              let converter = AVAudioConverter(
                  from: monoFormat, to: targetFormat),
              let playbackSourceFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(configuration.outputSampleRate),
                  channels: 1,
                  interleaved: false)
        else {
            let error = FullDuplexAudioError.invalidDeviceFormat
            setState(.failed(error.description))
            throw error
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(configuration.inputBufferFrames),
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            guard let self,
                  let source = buffer.floatChannelData,
                  buffer.frameLength > 0,
                  let mono = AVAudioPCMBuffer(
                      pcmFormat: monoFormat,
                      frameCapacity: buffer.frameCapacity)
            else { return }

            mono.frameLength = buffer.frameLength
            memcpy(
                mono.floatChannelData![0], source[0],
                Int(buffer.frameLength) * MemoryLayout<Float>.size)

            guard let samples = AudioIO.resampleMicrophoneBuffer(
                mono, with: converter, to: targetFormat),
                !samples.isEmpty
            else { return }

            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            guard self.setMicrophoneLevelIfRunning(
                sqrt(sum / Float(max(samples.count, 1))))
            else { return }
            onSamples(samples)
        }

        var playerAttached = false
        let attachPlayer = {
            engine.attach(playerNode)
            engine.connect(
                playerNode, to: engine.mainMixerNode, format: nil)
        }
        do {
            // The two paths need opposite orderings, and using the Voice
            // Processing ordering for both is what made `--no-aec` capture
            // nothing at all.
            //
            // With Voice Processing, the capture graph must start before any
            // playback source is added: `setVoiceProcessingEnabled` returns
            // before the macOS output client has finished moving from the
            // hardware rate to its negotiated rate, and starting here is the
            // synchronization boundary that makes the live format safe.
            //
            // Without it, the engine is an ordinary input/output graph, and
            // attaching a player after `start()` leaves the input tap silent
            // forever — measured as zero tap callbacks, on matched and
            // mismatched devices alike, while the same graph attached before
            // `start()` delivers ~10 callbacks per second. The session then
            // hangs, because frame-driven limits like `--max-seconds` never
            // advance without captured frames.
            if !configuration.enableAEC {
                attachPlayer()
                playerAttached = true
            }

            try engine.start()
            // ANTICHAT-PATCH: UP-SS-008 VPIO other-audio ducking at the minimum level (M3.T12, R-280 AC3)
            // Applied again once the engine runs: the voice-processing unit can come up with the system's default
            // (deeper) ducking (AT-280 AC3 measured −21 dB once with the setting applied only before the start).
            if configuration.enableAEC, otherAudioDuckingMinimum {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min)
            }
            // ANTICHAT-PATCH-END

            if !playerAttached {
                attachPlayer()
                playerAttached = true
            }
            let playbackFormat = playerNode.outputFormat(forBus: 0)
            guard playbackFormat.sampleRate > 0,
                  playbackFormat.channelCount > 0,
                  let playbackConverter = AVAudioConverter(
                      from: playbackSourceFormat, to: playbackFormat)
            else {
                throw FullDuplexAudioError.invalidDeviceFormat
            }

            // ANTICHAT-PATCH: UP-SS-009 output volume and end-of-input prebuffer flush (M3 review P1-3, P1-4)
            lock.lock()
            playerNode.volume = outputVolume
            lock.unlock()
            // ANTICHAT-PATCH-END
            lock.lock()
            self.engine = engine
            self.playerNode = playerNode
            self.playbackSourceFormat = playbackSourceFormat
            self.playbackFormat = playbackFormat
            self.playbackConverter = playbackConverter
            self.prebuffer = []
            self.playbackPrebufferTarget = configuration.playbackPrebufferFrames
            self.playbackStarted = false
            self.playbackGeneration &+= 1
            self.stopping = false
            self.scheduledBuffers = 0
            self.completedBuffers = 0
            self.underruns = 0
            self.audioState = .running
            lock.unlock()
            Self.log.info(
                "Full-duplex audio started: input \(self.configuration.inputSampleRate) Hz, output \(self.configuration.outputSampleRate) Hz, AEC \(self.configuration.enableAEC ? "on" : "off")")
        } catch {
            inputNode.removeTap(onBus: 0)
            if playerAttached {
                engine.disconnectNodeOutput(playerNode)
                engine.detach(playerNode)
            }
            engine.stop()
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Queue one contiguous model-audio chunk for echo-reference-aware output.
    // ANTICHAT-PATCH: UP-SS-007 output-only pause / resume / flush and per-buffer played callbacks (M3.T10 barge-in)
    /// `onPlayed` fires once the chunk has played back (never for a flushed one).
    public func schedulePlayback(_ samples: [Float], onPlayed: (@Sendable () -> Void)? = nil) {
        guard !samples.isEmpty else { return }
        lock.lock()
        let format = playbackSourceFormat
        let running = audioState == .running && !stopping
        lock.unlock()
        guard running, let format,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count))
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.floatChannelData![0].update(
                from: base, count: samples.count)
        }

        playbackQueue.async { [weak self] in
            self?.convertAndEnqueue(buffer, onPlayed: onPlayed)
        }
    }

    /// Pauses the output in place (queued audio is kept): the barge-in candidate on the first voiced frame.
    public func pausePlayback() {
        withPlaybackQueue {
            lock.lock()
            playbackPaused = true
            let node = playerNode
            lock.unlock()
            node?.pause()
        }
    }

    /// Resumes a paused output (a false barge-in: a cough, an "mm-hm").
    public func resumePlayback() {
        withPlaybackQueue {
            lock.lock()
            playbackPaused = false
            let node = playerNode
            let started = playbackStarted
            lock.unlock()
            if started { node?.play() }
        }
    }

    /// Drops every queued buffer (their `onPlayed` never fires) and silences the output now; capture keeps
    /// running and the next `schedulePlayback` starts a fresh burst.
    public func flushPlayback() {
        withPlaybackQueue {
            lock.lock()
            playbackGeneration &+= 1
            playbackPaused = false
            playbackStarted = false
            playbackPrebufferTarget = configuration.playbackPrebufferFrames
            let node = playerNode
            lock.unlock()
            prebuffer.removeAll(keepingCapacity: true)
            prebufferPlayed.removeAll(keepingCapacity: true)
            node?.stop()
        }
    }
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-SS-009 output volume and end-of-input prebuffer flush (M3 review P1-3, P1-4)
    /// Output volume of the player node, applied now (also to audio already queued) and kept across `start`.
    /// Speaker mute is volume 0: the buffers keep playing silently, so their played callbacks keep coming.
    public func setPlaybackVolume(_ volume: Float) {
        withPlaybackQueue {
            lock.lock()
            outputVolume = volume
            let node = playerNode
            lock.unlock()
            node?.volume = volume
        }
    }

    /// No more audio is coming for now (the end of a reply): a prebuffered burst shorter than the prebuffer target
    /// starts playing instead of waiting for buffers that never arrive.
    public func playPrebuffered() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.audioState == .running, !self.stopping, let node = self.playerNode, !self.playbackStarted,
                  !self.prebuffer.isEmpty else {
                self.lock.unlock()
                return
            }
            let generation = self.playbackGeneration
            let paused = self.playbackPaused
            self.lock.unlock()
            let pending = Array(zip(self.prebuffer, self.prebufferPlayed))
            self.prebuffer.removeAll(keepingCapacity: true)
            self.prebufferPlayed.removeAll(keepingCapacity: true)
            for (item, played) in pending {
                self.schedule(item, on: node, generation: generation, onPlayed: played)
            }
            self.lock.lock()
            self.playbackStarted = true
            self.lock.unlock()
            if !paused { node.play() }
        }
    }
    // ANTICHAT-PATCH-END

    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            scheduledBuffers: scheduledBuffers,
            completedBuffers: completedBuffers,
            underruns: underruns,
            microphoneLevel: microphoneLevel)
    }

    public func stop() {
        lock.lock()
        guard engine != nil || playerNode != nil else {
            audioState = .stopped
            lock.unlock()
            return
        }
        stopping = true
        playbackGeneration &+= 1
        let engine = self.engine
        let node = playerNode
        self.engine = nil
        playerNode = nil
        playbackSourceFormat = nil
        playbackFormat = nil
        playbackConverter = nil
        audioState = .stopped
        microphoneLevel = 0
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        withPlaybackQueue {
            node?.stop()
            // ANTICHAT-PATCH: UP-SS-007 output-only pause / resume / flush and per-buffer played callbacks (M3.T10 barge-in)
            prebuffer.removeAll(keepingCapacity: false)
            prebufferPlayed.removeAll(keepingCapacity: false)
            // ANTICHAT-PATCH-END
            playbackPrebufferTarget = configuration.playbackPrebufferFrames
            playbackStarted = false
        }
        if let engine, let node {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        engine?.stop()
    }

    deinit {
        stop()
    }

    // ANTICHAT-PATCH: UP-SS-007 output-only pause / resume / flush and per-buffer played callbacks (M3.T10 barge-in)
    private func convertAndEnqueue(_ source: AVAudioPCMBuffer, onPlayed: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let format = playbackFormat
        let converter = playbackConverter
        let running = audioState == .running && !stopping
        lock.unlock()
        guard running, let format, let converter,
              let buffer = Self.convertPlaybackBuffer(
                  source, with: converter, to: format),
              buffer.frameLength > 0
        else { return }
        enqueue(buffer, onPlayed: onPlayed)
    }

    /// Convert model-rate mono audio to the exact Voice Processing playback
    /// client format. Returning the PCM buffer directly preserves every
    /// output channel produced by `AVAudioConverter` (normally stereo on Mac).
    private static func convertPlaybackBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(inputBuffer.frameLength) * ratio).rounded(.up) + 16)
        guard capacity > 0,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil else { return nil }
        return outputBuffer
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, onPlayed: (@Sendable () -> Void)? = nil) {
        lock.lock()
        guard audioState == .running, !stopping, let node = playerNode else {
            lock.unlock()
            return
        }
        let started = playbackStarted
        let generation = playbackGeneration
        let paused = playbackPaused
        lock.unlock()

        if !started {
            prebuffer.append(buffer)
            prebufferPlayed.append(onPlayed)
            guard prebuffer.count >= playbackPrebufferTarget else {
                return
            }
            let pending = Array(zip(prebuffer, prebufferPlayed))
            prebuffer.removeAll(keepingCapacity: true)
            prebufferPlayed.removeAll(keepingCapacity: true)
            for (item, played) in pending {
                schedule(item, on: node, generation: generation, onPlayed: played)
            }
            lock.lock()
            playbackStarted = true
            lock.unlock()
            if !paused { node.play() }
            return
        }

        schedule(buffer, on: node, generation: generation, onPlayed: onPlayed)
        if !node.isPlaying, !paused { node.play() }
    }

    private func schedule(
        _ buffer: AVAudioPCMBuffer,
        on node: AVAudioPlayerNode,
        generation: Int,
        onPlayed: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        guard generation == playbackGeneration,
              playerNode === node,
              audioState == .running,
              !stopping else {
            lock.unlock()
            return
        }
        scheduledBuffers += 1
        lock.unlock()
        node.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.playbackQueue.async { [weak self] in
                guard let self else { return }
                if self.bufferCompleted(node: node, generation: generation) { onPlayed?() }
            }
        }
    }

    @discardableResult
    private func bufferCompleted(
        node: AVAudioPlayerNode,
        generation: Int
    ) -> Bool {
        lock.lock()
        guard generation == playbackGeneration,
              playerNode === node else {
            lock.unlock()
            return false
        }
        completedBuffers += 1
        let drained = completedBuffers == scheduledBuffers
            && audioState == .running && !stopping
        if drained {
            underruns += 1
            playbackStarted = false
            // Keep initial response latency low, but recover a starved stream
            // with enough queued audio to absorb sporadic slow MLX frames.
            // Reusing the three-frame startup cushion caused recurring audible
            // gaps whenever average generation hovered near 80 ms/frame.
            playbackPrebufferTarget = Self.recoveryPrebufferFrames(
                initial: configuration.playbackPrebufferFrames)
        }
        lock.unlock()
        if drained { node.pause() }
        return true
    }
    // ANTICHAT-PATCH-END

    private func setState(_ newState: State) {
        lock.lock()
        audioState = newState
        lock.unlock()
    }

    /// Publish capture state only while this engine generation is active, so
    /// an in-flight tap callback cannot deliver samples after `stop()`.
    private func setMicrophoneLevelIfRunning(_ level: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard audioState == .running, !stopping else { return false }
        microphoneLevel = level
        return true
    }

    /// Run teardown in-order without synchronously dispatching back onto the
    /// playback queue when the final strong reference is released there.
    private func withPlaybackQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: playbackQueueKey) != nil {
            body()
        } else {
            playbackQueue.sync(execute: body)
        }
    }
}

public enum FullDuplexAudioError: Error, CustomStringConvertible, LocalizedError {
    case invalidConfiguration(String)
    case invalidDeviceFormat

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "invalid full-duplex audio configuration: \(message)"
        case .invalidDeviceFormat:
            return "the selected audio device has no usable input/output format"
        }
    }

    public var errorDescription: String? { description }
}
// ANTICHAT-PATCH: UP-SS-003 the two AudioIO helpers FullDuplexAudioIO calls, copied from AudioCommon/AudioIO.swift:235-282 (the rest of AudioIO is not vendored)
enum AudioIO {
    static func enableVoiceProcessingIfRequested(
        _ enabled: Bool,
        setEnabled: (Bool) throws -> Void
    ) throws {
        guard enabled else { return }
        try setEnabled(true)
    }

    static func resampleMicrophoneBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(inputBuffer.frameLength) * ratio).rounded(.up) + 16)
        guard capacity > 0,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil else { return nil }

        let count = Int(outputBuffer.frameLength)
        guard count > 0, let data = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }
}
// ANTICHAT-PATCH-END
#endif
