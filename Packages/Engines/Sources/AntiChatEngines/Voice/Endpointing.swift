// Two-stage endpointing for the voice spike (M0.T05 step 2; P-media-03 §3–4).
// Stage 1: Silero VAD v6 on 32 ms frames (512 samples + 64 context at 16 kHz) with LSTM state, run
// directly on `silero-vad-unified-v6.0.0.mlmodelc` from the pinned `vad-files` repo. FluidAudio's
// `VadManager` streams 4,096-sample (256 ms) chunks, too coarse here (patches-media §P-media-03, RL-005).
// Stage 2: after ≥ 200 ms trailing silence ask SmartTurn v3.2 (vendored speech-swift); `complete`
// (p ≥ 0.5) ends the turn, otherwise keep listening up to 1.2 s of silence.
// The onset/offset hysteresis follows speech-swift `StreamingVADProcessor` (watch row in the allow-list).
@preconcurrency import CoreML
import Foundation
import SpeechSwiftVendored

/// Silero VAD v6, 32 ms frames, stateful.
public final class SileroFrameVAD {
    public static let frame = 512
    static let context = 64
    static let stateSize = 128
    public static let modelFile = "silero-vad-unified-v6.0.0.mlmodelc"

    private let model: MLModel
    private var h: MLMultiArray
    private var c: MLMultiArray
    private var ctx = [Float](repeating: 0, count: SileroFrameVAD.context)
    private let input: MLMultiArray

    public init(directory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        model = try MLModel(contentsOf: directory.appendingPathComponent(Self.modelFile), configuration: cfg)
        h = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        c = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.frame + Self.context)], dataType: .float32)
        reset()
    }

    public func reset() {
        for a in [h, c] {
            a.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Self.stateSize)
        }
        ctx = [Float](repeating: 0, count: Self.context)
    }

    /// Speech probability of one 512-sample frame.
    public func probability(_ frame: ArraySlice<Float>) throws -> Float {
        precondition(frame.count == Self.frame)
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        ctx.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: Self.context) }
        frame.withUnsafeBufferPointer { (p + Self.context).update(from: $0.baseAddress!, count: Self.frame) }
        let out = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: input),
                "hidden_state": MLFeatureValue(multiArray: h),
                "cell_state": MLFeatureValue(multiArray: c),
            ]))
        if let nh = out.featureValue(for: "new_hidden_state")?.multiArrayValue { h = nh }
        if let nc = out.featureValue(for: "new_cell_state")?.multiArrayValue { c = nc }
        ctx = Array(frame.suffix(Self.context))
        return out.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue ?? 0
    }
}

/// Pure endpointing state machine (unit-tested without models).
public struct Endpointer: Sendable {
    public struct Config: Sendable {
        public var threshold: Float = 0.5
        /// Silero-style hysteresis: leave speech below threshold − 0.15.
        public var negativeOffset: Float = 0.15
        /// Frames of speech needed to start a turn (2 × 32 ms).
        public var minSpeechFrames = 2
        public var smartTurnAfter: Double = 0.200
        public var maxSilence: Double = 1.200
        public var turnThreshold: Float = 0.5
        public init() {}
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Ask stage 2 (SmartTurn) now.
        case askTurn
        /// Turn over; `reason` is "smartTurn" or "maxSilence".
        case endTurn(reason: String)
    }

    public let config: Config
    public private(set) var inSpeech = false
    public private(set) var speechFrames = 0
    /// Index (frame number) where the current turn's speech started.
    public private(set) var speechStartFrame: Int?
    /// Index of the last frame classified as voiced.
    public private(set) var lastVoicedFrame: Int?
    private var silence: Double = 0
    private var asked = false
    private var turnSaidIncomplete = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public static let frameSeconds = Double(SileroFrameVAD.frame) / 16_000

    /// Feed one frame's VAD probability. `frameIndex` counts from 0.
    public mutating func feed(probability p: Float, frameIndex: Int) -> Action {
        let voiced = inSpeech ? p >= config.threshold - config.negativeOffset : p >= config.threshold
        if voiced {
            speechFrames += 1
            if !inSpeech, speechFrames >= config.minSpeechFrames {
                inSpeech = true
                speechStartFrame = frameIndex - speechFrames + 1
            }
            if inSpeech { lastVoicedFrame = frameIndex }
            silence = 0
            asked = false
            turnSaidIncomplete = false
            return .none
        }
        if !inSpeech {
            speechFrames = 0
            return .none
        }
        silence += Self.frameSeconds
        if silence >= config.maxSilence { return .endTurn(reason: "maxSilence") }
        if silence >= config.smartTurnAfter, !asked {
            asked = true
            return .askTurn
        }
        return .none
    }

    /// Stage-2 answer for the last `.askTurn`.
    public mutating func turnAnswer(probability: Float) -> Action {
        if probability >= config.turnThreshold { return .endTurn(reason: "smartTurn") }
        turnSaidIncomplete = true
        return .none
    }
}

/// SmartTurn v3.2 from the local `turn/coreml` directory (vendored speech-swift, UP-SS-002).
public enum SmartTurnLoader {
    public static func load(turnDirectory: URL) throws -> SmartTurnModel {
        let coreml = turnDirectory.appendingPathComponent("coreml")
        let dir = FileManager.default.fileExists(atPath: coreml.path) ? coreml : turnDirectory
        return try SmartTurnModel.fromPretrained(cacheDir: dir)
    }
}

/// End of speech from a waveform: end of the last 10 ms window above `dBFS` (the blackhole-mode
/// `tools/audio/last-voiced.py` uses the same rule).
public func lastVoicedSample(_ x: [Float], sampleRate: Int = 16_000, dBFS: Double = -50) -> Int? {
    let w = sampleRate / 100
    let thr = Float(pow(10, dBFS / 20))
    var i = (x.count / w) * w
    while i >= w {
        let s = x[(i - w)..<i]
        let rms = (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(w)).squareRoot()
        if rms > thr { return i }
        i -= w
    }
    return nil
}
