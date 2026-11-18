// M3.T09 step 1 (P-media-03): one `AVAudioEngine` per voice session — the vendored speech-swift `FullDuplexAudioIO`
// with VPIO on the input node and the TTS player node on the same engine (echo reference); 16 kHz mono Float32 frames
// of 512 samples (32 ms) to the VAD; a configuration change (route / device) rebuilds the graph. With `injected`
// (ScriptedVoice, tests and `-UseScriptedVoice`) VPIO is bypassed for determinism (mode inject [IN-PIPELINE]).
// M3 review: a rebuild reports that the queued output was lost (`onPlaybackReset`, P1-4: the sink re-bases its played
// clock); a rebuild that fails twice (300 ms apart) reports `onGraphFailed` (P2-3: the session ends with
// `voice.noDevice` instead of listening to nothing); speaker mute is the player volume (P1-3).
// 0.0.8 "old radio" fix: live, the reply plays on a separate plain engine (`PlainPlaybackDevice`, full band, never
// through VPIO) and capture without VPIO is a plain input tap (`MicCapture`) on the chosen mic: the user's Settings ›
// Voice › Microphone, else the built-in mic when the default input is a Bluetooth headset (`preferBuiltInMic`).
@preconcurrency import AVFoundation
import Foundation
import SpeechSwiftVendored

/// One VPIO capture/playback graph per conversation, with deterministic in-pipeline injection for tests.
public final class VoiceAudioEngine: AudioCaptureSource, VoicePlaybackDevice, @unchecked Sendable {
    private struct State {
        var io: FullDuplexAudioIO?
        /// Capture without VPIO (a plain input tap).
        var mic: MicCapture?
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
    private var config: (aec: Bool, duck: Bool, builtInMic: Bool)
    /// Settings › Voice › Microphone (nil = the system default).
    private let inputDeviceUID: String?
    /// The reply's output when it does not play into the VPIO graph (live sessions).
    let playback: PlainPlaybackDevice?
    /// M3.T12 (review finding 11): asked at each graph rebuild (a route / device change) for the new plan.
    public var planOnRebuild: (@Sendable () -> (enableAEC: Bool, duckingMinimum: Bool, preferBuiltInMic: Bool))? {
        get { lock.withLock { replan } }
        set { lock.withLock { replan = newValue } }
    }
    private var replan: (@Sendable () -> (enableAEC: Bool, duckingMinimum: Bool, preferBuiltInMic: Bool))?

    /// `enableAEC` = run the input through VPIO; `duckingMinimum` = VPIO ducks other audio no more than the minimum
    /// level (M3.T12, R-280 AC3; `HalfDuplexPolicy.plan`). `playback` = the reply's output; nil = a
    /// `PlainPlaybackDevice` for live capture, none for injected input.
    public init(
        injected: (any AudioCaptureSource)? = nil,
        outputSampleRate: Int = 24_000,
        enableAEC: Bool = true,
        duckingMinimum: Bool = true,
        preferBuiltInMic: Bool = false,
        inputDeviceUID: String? = nil,
        playback: PlainPlaybackDevice? = nil
    ) {
        self.injected = injected
        self.outputSampleRate = outputSampleRate
        self.inputDeviceUID = inputDeviceUID
        self.playback = playback ?? (injected == nil ? PlainPlaybackDevice(sampleRate: outputSampleRate) : nil)
        config = (enableAEC, duckingMinimum, preferBuiltInMic)
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
        if let playback { return playback.schedulePlayback(samples, onPlayed: onPlayed) }
        guard let io = lock.withLock({ state.io }), io.state == .running else { return false }
        io.schedulePlayback(samples, onPlayed: onPlayed)
        return true
    }

    /// Speaker mute (volume 0) / unmute: applies to the audio already queued (M3 review P1-3).
    public func setPlaybackVolume(_ volume: Float) {
        playback?.setPlaybackVolume(volume)
        let io = lock.withLock { () -> FullDuplexAudioIO? in
            state.volume = volume
            return state.io
        }
        io?.setPlaybackVolume(volume)
    }

    /// The end of a reply: a short burst still waiting in the prebuffer plays now (M3 review P1-4).
    public func playPrebuffered() {
        if let playback { return playback.playPrebuffered() }
        lock.withLock { state.io }?.playPrebuffered()
    }

    /// The graph was rebuilt (or lost): every queued buffer is gone and its `onPlayed` never fires.
    public var onPlaybackReset: (@Sendable () -> Void)? {
        get { playback?.onPlaybackReset ?? lock.withLock { state.onPlaybackReset } }
        set {
            if let playback { playback.onPlaybackReset = newValue } else { lock.withLock { state.onPlaybackReset = newValue } }
        }
    }

    /// A rebuild after a device change failed twice: capture has stopped for good.
    public var onGraphFailed: (@Sendable (Error) -> Void)? {
        get { lock.withLock { state.onGraphFailed } }
        set { lock.withLock { state.onGraphFailed = newValue } }
    }

    /// Output-only controls (capture keeps running): barge-in candidate / false alarm / confirmed (M3.T10).
    public func pausePlayback() {
        if let playback { return playback.pausePlayback() }
        lock.withLock { state.io }?.pausePlayback()
    }
    public func resumePlayback() {
        if let playback { return playback.resumePlayback() }
        lock.withLock { state.io }?.resumePlayback()
    }
    public func flushPlayback() {
        if let playback { return playback.flushPlayback() }
        lock.withLock { state.io }?.flushPlayback()
    }

    /// True when capture runs on the device (VPIO graph), false for injected (scripted) input.
    public var isLive: Bool { injected == nil }

    public func stop() {
        injected?.stop()
        playback?.stop()
        onGraphQueue {
            let old = lock.withLock { () -> (FullDuplexAudioIO?, MicCapture?, NSObjectProtocol?) in
                state.running = false
                state.generation &+= 1
                state.callback = nil
                state.pending.removeAll()
                defer { state.io = nil; state.mic = nil; state.observer = nil }
                return (state.io, state.mic, state.observer)
            }
            if let observer = old.2 { NotificationCenter.default.removeObserver(observer) }
            old.0?.stop()
            old.1?.stop()
        }
    }

    deinit {
        injected?.stop()
        let old = lock.withLock { () -> (FullDuplexAudioIO?, MicCapture?, NSObjectProtocol?) in
            defer { state.io = nil; state.mic = nil; state.observer = nil }
            return (state.io, state.mic, state.observer)
        }
        if let observer = old.2 { NotificationCenter.default.removeObserver(observer) }
        old.0?.stop()
        old.1?.stop()
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

    /// The mic a capture without VPIO listens on: the user's choice, else the built-in mic instead of a Bluetooth
    /// headset's (`preferBuiltInMic`), else the system default (nil).
    private var captureDeviceUID: String? {
        if let inputDeviceUID { return inputDeviceUID }
        return lock.withLock({ config.builtInMic }) ? VoiceAudioRouteProbe.builtInMicUIDIfBluetoothInput() : nil
    }

    private func startLive(aec: Bool) throws {
        if !aec { return try startPlainCapture() }
        let io = FullDuplexAudioIO(configuration: .init(
            inputSampleRate: 16_000,
            outputSampleRate: outputSampleRate,
            inputBufferFrames: 512,
            enableAEC: aec))
        io.otherAudioDuckingMinimum = aec && duckingMinimum
        io.setPlaybackVolume(lock.withLock { state.volume })
        let observer = observeConfigurationChanges()
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

    /// Capture without VPIO: a plain input tap on `captureDeviceUID` (nothing plays through this graph).
    private func startPlainCapture() throws {
        let mic = MicCapture(deviceUID: captureDeviceUID)
        let observer = observeConfigurationChanges()
        do {
            try mic.start { [weak self] in self?.receive($0) }
            lock.withLock { state.mic = mic; state.observer = observer; state.duckingLevel = nil }
        } catch {
            NotificationCenter.default.removeObserver(observer)
            lock.withLock { state.running = false }
            throw error
        }
    }

    private func observeConfigurationChanges() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.graphQueue.async { [weak self] in
                guard let self, self.lock.withLock({ self.state.running && self.hasGraph }) else { return }
                self.rebuildLive()
            }
        }
    }

    /// A capture graph runs (VPIO or plain); called under `lock`.
    private var hasGraph: Bool { state.io != nil || state.mic != nil }

    private func rebuildLive(retry: Bool = true) {
        let old = lock.withLock { () -> (FullDuplexAudioIO?, MicCapture?, NSObjectProtocol?) in
            defer { state.io = nil; state.mic = nil; state.observer = nil }
            return (state.io, state.mic, state.observer)
        }
        if let observer = old.2 { NotificationCenter.default.removeObserver(observer) }
        old.0?.stop()
        old.1?.stop()
        // The reply's own output (`PlainPlaybackDevice`) reports its own reset; only the VPIO graph's queue is lost here.
        if old.0 != nil, playback == nil, let reset = lock.withLock({ state.onPlaybackReset }) { reset() }
        if let plan = planOnRebuild?() {
            lock.withLock {
                // A new route can need VPIO again: a failure on the old device is not carried over.
                if plan.enableAEC != config.aec { state.aecFailed = false }
                config = (plan.enableAEC, plan.duckingMinimum, plan.preferBuiltInMic)
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
                    guard let self, self.lock.withLock({ self.state.running && self.state.generation == generation && !self.hasGraph })
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
