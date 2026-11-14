// M3.T09 step 1 (P-media-03): one `AVAudioEngine` per voice session — the vendored speech-swift `FullDuplexAudioIO`
// with VPIO on the input node and the TTS player node on the same engine (echo reference); 16 kHz mono Float32 frames
// of 512 samples (32 ms) to the VAD; a configuration change (route / device) rebuilds the graph. With `injected`
// (ScriptedVoice, tests and `-UseScriptedVoice`) VPIO is bypassed for determinism (mode inject [IN-PIPELINE]).
// M3 review: a rebuild reports that the queued output was lost (`onPlaybackReset`, P1-4: the sink re-bases its played
// clock); a rebuild that fails twice (300 ms apart) reports `onGraphFailed` (P2-3: the session ends with
// `voice.noDevice` instead of listening to nothing); speaker mute is the player volume (P1-3).
@preconcurrency import AVFoundation
import Foundation
import SpeechSwiftVendored

/// One VPIO capture/playback graph per conversation, with deterministic in-pipeline injection for tests.
public final class VoiceAudioEngine: AudioCaptureSource, VoicePlaybackDevice, @unchecked Sendable {
    private struct State {
        var io: FullDuplexAudioIO?
        var observer: NSObjectProtocol?
        var callback: (@Sendable ([Float]) -> Void)?
        var pending: [Float] = []
        var running = false
        var generation: UInt64 = 0
        /// M3.T12: VPIO was requested but could not be enabled; the graph runs without it (half duplex).
        var aecFailed = false
        var duckingLevel: String?
        var volume: Float = 1
        var onPlaybackReset: (@Sendable () -> Void)?
        var onGraphFailed: (@Sendable (Error) -> Void)?
    }
    /// The retry delay of a failed rebuild (M3 review P2-3).
    static let rebuildRetry: DispatchTimeInterval = .milliseconds(300)

    private let lock = NSLock()
    private var state = State()
    private let graphQueue = DispatchQueue(label: "app.antichat.voice.audio-graph", qos: .userInteractive)
    private let graphKey = DispatchSpecificKey<Void>()
    private let injected: (any AudioCaptureSource)?
    private let outputSampleRate: Int
    private var enableAEC: Bool { lock.withLock { config.aec } }
    private var duckingMinimum: Bool { lock.withLock { config.duck } }
    private var config: (aec: Bool, duck: Bool)
    /// M3.T12 (review finding 11): asked at each graph rebuild (a route / device change) for the new plan.
    public var planOnRebuild: (@Sendable () -> (enableAEC: Bool, duckingMinimum: Bool))? {
        get { lock.withLock { replan } }
        set { lock.withLock { replan = newValue } }
    }
    private var replan: (@Sendable () -> (enableAEC: Bool, duckingMinimum: Bool))?

    /// `enableAEC` = run the input through VPIO; `duckingMinimum` = VPIO ducks other audio no more than the minimum
    /// level (M3.T12, R-280 AC3; `HalfDuplexPolicy.plan`).
    public init(
        injected: (any AudioCaptureSource)? = nil,
        outputSampleRate: Int = 24_000,
        enableAEC: Bool = true,
        duckingMinimum: Bool = true
    ) {
        self.injected = injected
        self.outputSampleRate = outputSampleRate
        config = (enableAEC, duckingMinimum)
        graphQueue.setSpecific(key: graphKey, value: ())
    }

    public var isEchoCancellationActive: Bool {
        lock.withLock { state.running && state.io != nil && config.aec && !state.aecFailed }
    }

    /// M3.T12: VPIO was requested and could not be enabled (the session falls back to half duplex).
    public var echoCancellationFailed: Bool { lock.withLock { state.aecFailed } }

    /// M3.T12: the ducking the live graph applied (`"min"`, nil = none / injected input).
    public var appliedDuckingLevel: String? { lock.withLock { state.duckingLevel } }

    public func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        lock.withLock {
            state.callback = onSamples
            state.running = true
            state.generation &+= 1
        }
        if let injected {
            do {
                try injected.start { [weak self] in self?.receive($0) }
            } catch {
                lock.withLock { state.running = false }
                throw error
            }
        } else {
            try onGraphQueue { try startLive() }
        }
    }

    /// TTS into the VPIO graph (the echo reference); `onPlayed` after the buffer played (never for a flushed one).
    /// False: no running graph (a rebuild in progress, stopped): the samples are dropped and never play.
    @discardableResult
    public func schedulePlayback(_ samples: [Float], onPlayed: (@Sendable () -> Void)? = nil) -> Bool {
        guard let io = lock.withLock({ state.io }), io.state == .running else { return false }
        io.schedulePlayback(samples, onPlayed: onPlayed)
        return true
    }

    /// Speaker mute (volume 0) / unmute: applies to the audio already queued (M3 review P1-3).
    public func setPlaybackVolume(_ volume: Float) {
        let io = lock.withLock { () -> FullDuplexAudioIO? in
            state.volume = volume
            return state.io
        }
        io?.setPlaybackVolume(volume)
    }

    /// The end of a reply: a short burst still waiting in the prebuffer plays now (M3 review P1-4).
    public func playPrebuffered() { lock.withLock { state.io }?.playPrebuffered() }

    /// The graph was rebuilt (or lost): every queued buffer is gone and its `onPlayed` never fires.
    public var onPlaybackReset: (@Sendable () -> Void)? {
        get { lock.withLock { state.onPlaybackReset } }
        set { lock.withLock { state.onPlaybackReset = newValue } }
    }

    /// A rebuild after a device change failed twice: capture has stopped for good.
    public var onGraphFailed: (@Sendable (Error) -> Void)? {
        get { lock.withLock { state.onGraphFailed } }
        set { lock.withLock { state.onGraphFailed = newValue } }
    }

    /// Output-only controls (capture keeps running): barge-in candidate / false alarm / confirmed (M3.T10).
    public func pausePlayback() { lock.withLock { state.io }?.pausePlayback() }
    public func resumePlayback() { lock.withLock { state.io }?.resumePlayback() }
    public func flushPlayback() { lock.withLock { state.io }?.flushPlayback() }

    /// True when capture runs on the device (VPIO graph), false for injected (scripted) input.
    public var isLive: Bool { injected == nil }

    public func stop() {
        injected?.stop()
        onGraphQueue {
            let old = lock.withLock { () -> (FullDuplexAudioIO?, NSObjectProtocol?) in
                state.running = false
                state.generation &+= 1
                state.callback = nil
                state.pending.removeAll()
                defer { state.io = nil; state.observer = nil }
                return (state.io, state.observer)
            }
            if let observer = old.1 { NotificationCenter.default.removeObserver(observer) }
            old.0?.stop()
        }
    }

    deinit {
        injected?.stop()
        let old = lock.withLock { () -> (FullDuplexAudioIO?, NSObjectProtocol?) in
            defer { state.io = nil; state.observer = nil }
            return (state.io, state.observer)
        }
        if let observer = old.1 { NotificationCenter.default.removeObserver(observer) }
        old.0?.stop()
    }

    private func startLive() throws {
        do {
            try startLive(aec: enableAEC && !lock.withLock({ state.aecFailed }))
        } catch where enableAEC && !lock.withLock({ state.aecFailed }) {
            // M3.T12 step 2: `setVoiceProcessingEnabled(true)` failed → the same graph without VPIO (half duplex).
            lock.withLock { state.aecFailed = true; state.running = true }
            try startLive(aec: false)
        }
    }

    private func startLive(aec: Bool) throws {
        let io = FullDuplexAudioIO(configuration: .init(
            inputSampleRate: 16_000,
            outputSampleRate: outputSampleRate,
            inputBufferFrames: 512,
            enableAEC: aec))
        io.otherAudioDuckingMinimum = aec && duckingMinimum
        io.setPlaybackVolume(lock.withLock { state.volume })
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.graphQueue.async { [weak self] in
                guard let self, self.lock.withLock({ self.state.running && self.state.io != nil }) else { return }
                self.rebuildLive()
            }
        }
        do {
            try io.start { [weak self] in self?.receive($0) }
            lock.withLock { state.io = io; state.observer = observer; state.duckingLevel = io.appliedDuckingLevel }
        } catch {
            NotificationCenter.default.removeObserver(observer)
            io.stop()
            lock.withLock { state.running = false }
            throw error
        }
    }

    private func rebuildLive(retry: Bool = true) {
        let old = lock.withLock { () -> (FullDuplexAudioIO?, NSObjectProtocol?) in
            defer { state.io = nil; state.observer = nil }
            return (state.io, state.observer)
        }
        if let observer = old.1 { NotificationCenter.default.removeObserver(observer) }
        old.0?.stop()
        if old.0 != nil, let reset = lock.withLock({ state.onPlaybackReset }) { reset() }
        if let plan = planOnRebuild?() {
            lock.withLock {
                // A new route can need VPIO again: a failure on the old device is not carried over.
                if plan.enableAEC != config.aec { state.aecFailed = false }
                config = (plan.enableAEC, plan.duckingMinimum)
            }
        }
        do { try startLive() } catch {
            // M3 review P2-3: try once more shortly (the new device may still be settling), then say so.
            let generation = lock.withLock { () -> UInt64 in
                state.running = retry
                return state.generation
            }
            if retry {
                graphQueue.asyncAfter(deadline: .now() + Self.rebuildRetry) { [weak self] in
                    guard let self, self.lock.withLock({ self.state.running && self.state.generation == generation && self.state.io == nil })
                    else { return }
                    self.rebuildLive(retry: false)
                }
            } else {
                lock.withLock { state.onGraphFailed }?(error)
            }
        }
    }

    private func receive(_ samples: [Float]) {
        let frames = lock.withLock { () -> [(@Sendable ([Float]) -> Void, [Float])] in
            guard state.running else { return [] }
            state.pending.append(contentsOf: samples)
            var out: [(@Sendable ([Float]) -> Void, [Float])] = []
            while state.pending.count >= 512, let callback = state.callback {
                out.append((callback, Array(state.pending.prefix(512))))
                state.pending.removeFirst(512)
            }
            return out
        }
        for (callback, frame) in frames { callback(frame) }
    }

    private func onGraphQueue(_ body: () throws -> Void) rethrows {
        if DispatchQueue.getSpecific(key: graphKey) != nil { try body() } else { try graphQueue.sync(execute: body) }
    }
}
