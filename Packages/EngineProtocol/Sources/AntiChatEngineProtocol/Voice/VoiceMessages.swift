// M3.T01 (architecture §4.3 "Voice"; G-036…G-039): the app ↔ helper voice contract. The helper owns capture,
// VAD, STT, TTS and playback (AT-M0-05: the TCC prompt names AntiChat with helper capture), so the app only
// sends these messages and renders `VoiceEvent`s. Voice events travel as `StreamItem.voice`, apart from
// `EngineEvent`, so the R-229 chat adapter contract stays exactly seven events. Every request stream still ends
// with one terminal `EngineEvent` (`done` / `error`). The M0.T05 spike lane (`ClientMessage.voice(VoiceRequest)`)
// stays for the `-Bench voice` probe until M3.T09–T11 replace it.
import Foundation

// MARK: - Shared value types

/// Which recogniser produced a transcript (R-281 AC1 `engine == speechAnalyzer`, R-284 routing).
public enum STTEngineID: String, Codable, Sendable, Hashable, CaseIterable {
    case parakeet, whisperkit, speechAnalyzer
}

/// One timed piece of a transcript (seconds from the start of the audio).
public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// The final result of a dictation, a voice turn or a file (`FinalTranscript`, M3.T03 step 1).
public struct FinalTranscript: Codable, Sendable, Hashable {
    public var text: String
    /// BCP-47 language code the router settled on (R-284), e.g. "en", "ja".
    public var language: String
    public var engine: STTEngineID
    public var segments: [TranscriptSegment]
    /// The recogniser's confidence 0…1 when it reports one (Parakeet; AT-284 auto routing). Optional on the wire.
    public var confidence: Float?

    public init(text: String, language: String, engine: STTEngineID, segments: [TranscriptSegment] = [], confidence: Float? = nil) {
        self.text = text
        self.language = language
        self.engine = engine
        self.segments = segments
        self.confidence = confidence
    }
}

/// The Voice pack's model roles (model-matrix §1 keys). `turn-coreml` is the Core ML packaging of smart-turn v3.2
/// that the vendored `SmartTurn.swift` loads (A-M3-01); `stt-multi` is on demand (M3.T05).
public enum VoiceModelRole: String, Codable, Sendable, Hashable, CaseIterable {
    case stt, sttEOU, sttMulti, vad, turn, tts

    /// The catalog key of the role's model.
    public var catalogKey: String {
        switch self {
        case .stt: "stt"
        case .sttEOU: "stt-eou"
        case .sttMulti: "stt-multi"
        case .vad: "vad-files"
        case .turn: "turn-coreml"
        case .tts: "tts"
        }
    }

    public init?(catalogKey: String) {
        guard let r = Self.allCases.first(where: { $0.catalogKey == catalogKey }) else { return nil }
        self = r
    }

    /// The role's model directory in a developer models root (`~/Library/Application Support/AntiChat-Dev/Models`),
    /// the folder the app's dev voice fallback and every `-Bench` voice mode hand the helper. Always the role's
    /// catalog key, like the shipping app's install views (`SetupLaunch.installedVoiceModelSet`):
    ///   1. the install view `installs/<catalogKey>` (has `manifest.json`; `make models-dev`),
    ///   2. the pre-M2 folder `<root>/<catalogKey>`,
    ///   3. `turn` only: the M0 layout's `<root>/turn` when it holds `coreml/` (`SmartTurnLoader` picks that subfolder).
    /// Never `installs/turn`: catalog id `turn` is the ONNX packaging (`smart-turn-v3.2-cpu.onnx`), which SmartTurn
    /// cannot load. M0's dev key `turn` meant onnx/ + coreml/; since M2.T12 `models install --id turn` resolves the
    /// product catalog's ONNX-only `turn`, so a dev store with `installs/turn` and no `turn-coreml` had no turn model
    /// (Q-015 r3, M9.T05 `-Bench voice-session` "voice models missing"). nil = not installed.
    public func developerDirectory(in root: URL, fileManager fm: FileManager = .default) -> URL? {
        let view = root.appendingPathComponent("installs").appendingPathComponent(catalogKey)
        if fm.fileExists(atPath: view.appendingPathComponent("manifest.json").path) { return view }
        let legacy = root.appendingPathComponent(catalogKey)
        if fm.fileExists(atPath: legacy.path) { return legacy }
        if self == .turn {
            let m0 = root.appendingPathComponent("turn")
            if fm.fileExists(atPath: m0.appendingPathComponent("coreml").path) { return m0 }
        }
        return nil
    }
}

/// The installed and verified voice models (G-052 `ready`), sent by the app at connect and after each install or
/// removal. Paths are the model store's install views (D-11: the helper never downloads); footprints come from
/// the catalog. A role missing here is not installed.
public struct VoiceModelSet: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var slots: [VoiceModelRole: ModelSlot]

    public init(requestID: UUID = UUID(), slots: [VoiceModelRole: ModelSlot]) {
        self.requestID = requestID
        self.slots = slots
    }
}

// MARK: - Requests

public struct DictationStart: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var locale: String?
    public var deviceUID: String?
    /// M3.T03 (R-050 AC4): where the helper writes the finished dictation's audio (16 kHz mono AAC `.m4a`) before
    /// its `finalTranscript`; nil = keep no audio (incognito, contract 3). Never written for a cancel or an empty
    /// (silence-only) result.
    public var recordingURL: URL?
    /// M3.T03 (DEBUG / tests only; environment §5): a ScriptedVoice script (`{t_ms, wav, gain_db}` lines) the helper
    /// captures from instead of the microphone (`-UseScriptedVoice`). Release helpers ignore it.
    public var scriptedInput: String?

    public init(requestID: UUID = UUID(), locale: String? = nil, deviceUID: String? = nil, recordingURL: URL? = nil,
                scriptedInput: String? = nil) {
        self.requestID = requestID
        self.locale = locale
        self.deviceUID = deviceUID
        self.recordingURL = recordingURL
        self.scriptedInput = scriptedInput
    }
}

public struct DictationStop: Codable, Sendable, Hashable {
    /// ■ stop-to-review, ↑ send-now, × cancel (S-17, IS-9).
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable { case review, sendNow, cancel }
    /// The `DictationStart.requestID` this stops.
    public var requestID: UUID
    public var mode: Mode

    public init(requestID: UUID, mode: Mode) {
        self.requestID = requestID
        self.mode = mode
    }
}

public struct TranscribeFile: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var fileURL: URL
    public var locale: String?

    public init(requestID: UUID = UUID(), fileURL: URL, locale: String? = nil) {
        self.requestID = requestID
        self.fileURL = fileURL
        self.locale = locale
    }
}

public struct VoiceSessionStart: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable { case handsFree, pushToTalk }
    public var requestID: UUID
    public var chatID: UUID
    public var mode: Mode
    public var locale: String?
    public var voiceID: String
    /// 0.75…1.5 (R-053).
    public var rate: Float
    public var deviceUID: String?
    public var duckOthers: Bool
    /// M3.T11 (DEBUG / tests only, like `DictationStart.scriptedInput`): a ScriptedVoice script the helper captures
    /// from instead of the microphone (`-UseScriptedVoice`); VPIO is bypassed. Release helpers ignore it.
    public var scriptedInput: String?
    /// M3.T10: the localized `voice.codeOmitted` sentence a fenced code block of a spoken reply becomes.
    public var codeOmitted: String?
    /// M3.T12 (DEBUG / tests only): `aec=unavailable`, `route=headphones|speakers|noaec` (`-FakeAEC`,
    /// `-FakeAudioRoute`). Release helpers ignore it.
    public var fakeAudio: String?

    public init(
        requestID: UUID = UUID(), chatID: UUID, mode: Mode = .handsFree, locale: String? = nil, voiceID: String,
        rate: Float = 1, deviceUID: String? = nil, duckOthers: Bool = true, scriptedInput: String? = nil,
        codeOmitted: String? = nil, fakeAudio: String? = nil
    ) {
        self.fakeAudio = fakeAudio
        self.requestID = requestID
        self.chatID = chatID
        self.mode = mode
        self.locale = locale
        self.voiceID = voiceID
        self.rate = rate
        self.deviceUID = deviceUID
        self.duckOthers = duckOthers
        self.scriptedInput = scriptedInput
        self.codeOmitted = codeOmitted
    }
}

public struct VoiceSessionControl: Codable, Sendable, Hashable {
    public enum Action: Codable, Sendable, Hashable {
        case muteMic, unmuteMic, muteSpeaker, unmuteSpeaker, pttDown, pttUp
        /// Speak this text as the assistant turn `turnID`: the reply's raw Markdown, streamed as deltas in order (the
        /// helper chunks it clause by clause, M3.T10; `spokenSpan` offsets are UTF-16 offsets into the concatenation).
        case speak(text: String, turnID: UUID)
        /// M3.T10: the reply text of `turnID` is complete (the last chunk is spoken, then `ttsStopped(.finished)`).
        case speakEnd(turnID: UUID)
        /// Stop playback and drop queued TTS (barge-in, typed message).
        case flush
        /// A-M3-T09c (NFR-V1): the reply the chat is generating speculatively from the pause transcript begins with
        /// `text` (raw Markdown so far). The helper may synthesise its first chunk ahead of time; nothing is played
        /// unless a `speak` of the adopted reply produces the very same chunk.
        case speculate(text: String)
        case setRate(Float)
        case setVoice(String)
    }

    /// The `VoiceSessionStart.requestID` of the session.
    public var requestID: UUID
    public var action: Action

    public init(requestID: UUID, action: Action) {
        self.requestID = requestID
        self.action = action
    }
}

public struct VoiceSessionEnd: Codable, Sendable, Hashable {
    public var requestID: UUID
    public init(requestID: UUID) { self.requestID = requestID }
}

public struct Speak: Codable, Sendable, Hashable {
    public enum Purpose: String, Codable, Sendable, Hashable, CaseIterable { case readAloud, preview }
    public var requestID: UUID
    public var text: String
    public var voiceID: String
    public var rate: Float
    public var purpose: Purpose
    /// M3.T07 (R-054 AC2): the localized `voice.codeOmitted` sentence each fenced code block becomes (nil = English).
    public var codeOmitted: String?
    /// M9.T05 (DEBUG / benches only, like `DictationStart.scriptedInput`; a Release helper ignores it): Kokoro plays
    /// into a silent clock instead of the speakers (`-Bench read-aloud`, NFR-V8 [IN-PIPELINE]).
    public var silentOutput: Bool?

    public init(requestID: UUID = UUID(), text: String, voiceID: String, rate: Float = 1, purpose: Purpose = .readAloud,
                codeOmitted: String? = nil, silentOutput: Bool? = nil) {
        self.requestID = requestID
        self.text = text
        self.voiceID = voiceID
        self.rate = rate
        self.purpose = purpose
        self.codeOmitted = codeOmitted
        self.silentOutput = silentOutput
    }
}

public struct SpeakStop: Codable, Sendable, Hashable {
    /// The `Speak.requestID` to stop.
    public var requestID: UUID
    public init(requestID: UUID) { self.requestID = requestID }
}

/// One voice request on the wire (`ClientMessage.voiceService`). `requestID` names the stream its events go to:
/// starts open a stream; stop / control / end address the stream they started.
public enum VoiceMessage: Codable, Sendable, Hashable {
    case dictationStart(DictationStart)
    case dictationStop(DictationStop)
    case transcribeFile(TranscribeFile)
    case sessionStart(VoiceSessionStart)
    case sessionControl(VoiceSessionControl)
    case sessionEnd(VoiceSessionEnd)
    case speak(Speak)
    case speakStop(SpeakStop)
    /// Registers the installed voice models (answered with `done`).
    case models(VoiceModelSet)

    public var requestID: UUID {
        switch self {
        case .dictationStart(let m): m.requestID
        case .dictationStop(let m): m.requestID
        case .transcribeFile(let m): m.requestID
        case .sessionStart(let m): m.requestID
        case .sessionControl(let m): m.requestID
        case .sessionEnd(let m): m.requestID
        case .speak(let m): m.requestID
        case .speakStop(let m): m.requestID
        case .models(let m): m.requestID
        }
    }

    /// True for messages that open a new stream (the others act on one that is already open).
    public var opensStream: Bool {
        switch self {
        case .dictationStart, .transcribeFile, .sessionStart, .speak, .models: true
        case .dictationStop, .sessionControl, .sessionEnd, .speakStop: false
        }
    }
}

// MARK: - Events

public enum VoiceTurnEndReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// Stage 2 (smart-turn) said complete.
    case smartTurn
    /// The streaming EOU model ended the turn.
    case eou
    /// The 1.5 s silence cap (R-283).
    case silenceCap
    /// Push-to-talk released.
    case ptt
}

public enum TTSStopReason: String, Codable, Sendable, Hashable, CaseIterable {
    case finished, bargeIn, stopped, flushed, failed
}

public enum VoiceState: String, Codable, Sendable, Hashable, CaseIterable {
    case idle, listening, transcribing, thinking, speaking, halfDuplex
}

/// Helper → app voice events (`StreamItem.voice`).
public enum VoiceEvent: Codable, Sendable, Hashable {
    /// Input level, RMS dBFS (≈ 30 Hz while capturing).
    case audioLevel(Float)
    case partialTranscript(String)
    case finalTranscript(FinalTranscript)
    /// NFR-V1: a voice conversation's turn paused (stage 1 heard a short silence) and this is the transcript so far.
    /// It becomes the final unchanged when the turn ends without more speech; the app prefills the chat model's
    /// prompt with it meanwhile (speculative, nothing is stored or shown; a later partial means the user went on).
    case provisionalTranscript(String)
    case turnEnded(VoiceTurnEndReason)
    case ttsStarted(chunkIndex: Int)
    /// M3.T11 (R-052 AC5): the sentence a voice conversation is speaking now (the live caption under the orb).
    case speakingText(String)
    /// M3.T11 (NFR-V1/V2/V3 probes): a voice-session stage at helper host time `hostNs` (`clock_gettime_nsec_np(
    /// CLOCK_UPTIME_RAW)`, the same clock in every process): `voice.lastVoicedFrame`, `voice.turnEnded`,
    /// `voice.finalTranscript`, `tts.firstClauseReady`, `tts.firstChunkSynth`, `tts.firstSample`, `voice.bargeOnset`,
    /// `tts.silent`. The UI ignores it.
    case signpost(name: String, hostNs: UInt64)
    case ttsStopped(playedMs: Double, reason: TTSStopReason)
    /// The assistant text of `turnID` actually spoken so far (R-282 AC2 truncation point).
    case spokenSpan(turnID: UUID, charOffset: Int)
    case voiceState(VoiceState)
    /// File transcription progress 0…100, monotonic, from processed seconds ÷ duration (R-056).
    case transcribeProgress(Double)
}
