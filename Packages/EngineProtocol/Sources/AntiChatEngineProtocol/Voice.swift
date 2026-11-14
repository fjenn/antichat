// Voice spike messages (M0.T05, S-9): the app asks the helper to run one voice turn; the helper owns
// capture/injection, endpointing, STT, the LLM call, TTS and playback (10-architecture/DIGEST.md §5 item 9)
// and returns one `VoiceTurnReport` with helper-side timestamps. Prototype for G-037 (M3).
import Foundation

public enum VoiceInputMode: String, Codable, Sendable, Hashable {
    /// `[IN-PIPELINE]`: PCM from a file fed into the capture path at real-time pace (no device latency).
    case inject
    /// BlackHole 2ch virtual device (needs P-ADMIN).
    case blackhole
    /// Real default microphone for n seconds, RMS only (TCC check; never V1 numbers).
    case live
}

public enum VoiceTTSEngine: String, Codable, Sendable, Hashable {
    /// FluidAudio KokoroAneManager (P-media-04).
    case kokoro
    /// AVSpeechSynthesizer (D-010 fallback).
    case system
}

/// Local model directories of the resident voice set (model-matrix §1: stt, vad-files, turn, tts).
public struct VoiceModelPaths: Codable, Sendable, Hashable {
    public var stt: String
    public var vad: String
    public var turn: String
    public var tts: String

    public init(stt: String, vad: String, turn: String, tts: String) {
        self.stt = stt
        self.vad = vad
        self.turn = turn
        self.tts = tts
    }
}

public struct VoiceRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var mode: VoiceInputMode
    /// Audio file for `inject` (any AVFoundation format; converted to 16 kHz mono).
    public var inputPath: String?
    /// Capture length for `live`.
    public var liveSeconds: Double
    public var models: VoiceModelPaths
    public var chat: ModelSlot
    public var systemPrompt: String
    public var maxTokens: Int
    public var tts: VoiceTTSEngine
    /// Test hook for K-NEW-ENG-9: make the Kokoro path fail so the automatic SystemTTS fallback engages.
    public var simulateKokoroFailure: Bool
    /// Output volume of the playback engine (0 keeps bench runs silent; buffers are still scheduled).
    public var outputVolume: Float
    /// Optional path to write the synthesized first sentence (WAV) for inspection.
    public var recordOutputPath: String?
    /// Run the pipeline once without reporting (warm caches / compiled kernels).
    public var warmup: Bool

    public init(
        requestID: UUID = UUID(), mode: VoiceInputMode, inputPath: String? = nil, liveSeconds: Double = 3,
        models: VoiceModelPaths, chat: ModelSlot, systemPrompt: String, maxTokens: Int = 80, tts: VoiceTTSEngine = .kokoro,
        simulateKokoroFailure: Bool = false, outputVolume: Float = 0, recordOutputPath: String? = nil, warmup: Bool = false
    ) {
        self.requestID = requestID
        self.mode = mode
        self.inputPath = inputPath
        self.liveSeconds = liveSeconds
        self.models = models
        self.chat = chat
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.tts = tts
        self.simulateKokoroFailure = simulateKokoroFailure
        self.outputVolume = outputVolume
        self.recordOutputPath = recordOutputPath
        self.warmup = warmup
    }
}

/// One voice turn, measured in the helper (seconds on one monotonic clock, relative to the first
/// injected/captured sample). nil = the stage did not happen.
public struct VoiceTurnReport: Codable, Sendable, Hashable {
    public var mode: VoiceInputMode
    public var ttsUsed: VoiceTTSEngine
    public var kokoroError: String?
    /// Last VAD-voiced frame end (NFR-V1 "end of user speech").
    public var lastVoiced: Double?
    /// Waveform end of speech (last 10 ms window above −50 dBFS), inject mode only.
    public var waveformEndOfSpeech: Double?
    public var turnEnd: Double?
    /// "smartTurn" (stage 2 said complete) or "maxSilence" (1.2 s fallback) or "inputEnded".
    public var turnEndReason: String?
    public var smartTurnProbability: Float?
    public var transcriptFinal: Double?
    public var firstToken: Double?
    public var firstSentence: Double?
    public var firstTTSBuffer: Double?
    public var firstOutputBuffer: Double?
    public var transcript: String
    public var reply: String
    public var firstSentenceText: String
    public var speechSeconds: Double
    public var stageMillis: [String: Double]
    /// live mode: RMS of the captured audio (dBFS) and captured frames.
    public var liveRMSdBFS: Double?
    public var liveFrames: Int?
    public var liveMicrophone: String?
    public var mtlAllocatedBytes: UInt64
    public var gpuPeakBytes: UInt64
    public var error: String?

    public init(mode: VoiceInputMode, ttsUsed: VoiceTTSEngine) {
        self.mode = mode
        self.ttsUsed = ttsUsed
        transcript = ""
        reply = ""
        firstSentenceText = ""
        speechSeconds = 0
        stageMillis = [:]
        mtlAllocatedBytes = 0
        gpuPeakBytes = 0
    }

    /// NFR-V1: last voiced frame → first output buffer.
    public var v1: Double? {
        guard let a = lastVoiced, let b = firstOutputBuffer else { return nil }
        return b - a
    }
}
