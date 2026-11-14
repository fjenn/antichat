// M3.T03 (R-050, S-17, IS-9; app side of M3 contract 1): one composer's dictation. The helper captures and
// recognises; this controller only sends `DictationStart` / `DictationStop` and renders the `VoiceEvent`s.
//   idle → recording (the DictationBar shows at once, NFR-V5) → finalizing (■ / ↑) → done(text) | empty | cancelled
//   | failed. × cancel from recording or finalizing → cancelled.
// ■ stop-to-review hands the final text to `onReview` (the composer field, for editing); ↑ send-now to `onSendNow`
// (sent as a user message). An empty final (silence only, R-050 AC3) returns to an empty composer: no error, no toast.
// Recent recordings (AC4): unless incognito, the helper writes the audio to a temp `.m4a` this controller names and
// `onRecording` files it (RecordingStore, keep 20) once the stream ends; incognito names no file (contract 3).
// Models: the installed voice slots (`models()`) are registered with the helper before every start (`VoiceModelSet`;
// cheap, and a restarted helper has none). Signposts: `dictation.click` → `dictation.indicator` (V5).
// M3 review P1-6: a dictation whose controller goes away (window closed: `teardown`; the controller released: the
// pump sees it) is cancelled in the helper, never left recording. P2-8: one dictation or call app-wide holds the mic
// (`VoiceCalls`): a dictation does not start while a call runs in another window.
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
public final class DictationController {
    public enum Phase: Equatable, Sendable {
        case idle, recording, finalizing
        case done(String)
        case empty, cancelled
        case failed(String)

        public var isActive: Bool { self == .recording || self == .finalizing }
    }

    /// What a finished, non-incognito dictation leaves for Recent recordings.
    public struct Recording: Sendable, Equatable {
        public var audio: URL
        public var transcript: String
        public var language: String
        public var engine: STTEngineID
        public var chatID: String?
    }

    public private(set) var phase: Phase = .idle {
        didSet { if phase.isActive != oldValue.isActive { calls.dictation(ObjectIdentifier(self), active: phase.isActive) } }
    }
    /// The live partial (grey, `text.secondary`) while recording.
    public private(set) var partial = ""
    /// The last ≈ 1.6 s of input levels (dBFS, 30 Hz) for the waveform dots.
    public private(set) var levels: [Float] = []
    /// Level updates received (AT-050 AC1: the waveform changes ≥ 5 times in 2 s of speech).
    public private(set) var levelUpdates = 0
    public private(set) var startedAt: Date?
    /// M3.T04: this dictation runs on Basic voice (no verified Voice pack when it started; "Basic voice" label).
    public private(set) var isBasic = false

    @ObservationIgnored public var onReview: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onSendNow: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onRecording: (@MainActor (Recording) -> Void)?

    @ObservationIgnored let engine: any EngineService
    @ObservationIgnored let models: @MainActor () -> VoiceModelSet
    @ObservationIgnored let scriptedInput: String?
    @ObservationIgnored let tempDir: URL
    /// The app-wide mic holders (P2-5 / P2-8); tests pass their own.
    @ObservationIgnored let calls: VoiceCalls
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var mode: DictationStop.Mode?
    @ObservationIgnored private var stopSent = false
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var chatID: String?
    @ObservationIgnored private var final: FinalTranscript?
    @ObservationIgnored private var pump: Task<Void, Never>?
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")
    public static let waveformCount = 48

    public init(engine: any EngineService, models: @escaping @MainActor () -> VoiceModelSet,
                scriptedInput: String? = LaunchOptions.current.scriptedVoiceScript,
                tempDir: URL = VoiceTemp.directory(VoiceTemp.dictation),  // M3 review P2-6: swept after a crash
                calls: VoiceCalls = .shared) {
        self.calls = calls
        self.engine = engine
        self.models = models
        self.scriptedInput = scriptedInput.map(Self.absoluteScript)
        self.tempDir = tempDir
    }

    isolated deinit {
        // A controller released mid-dictation (its pump cancels the helper side) no longer holds the mic.
        calls.dictation(ObjectIdentifier(self), active: false)
    }

    /// The helper needs an absolute script path; a relative one (UI tests pass `fixtures/voice/scripts/…`) resolves
    /// against the working directory, then `$ANTICHAT_FIXTURES` (with or without its leading `fixtures/`).
    static func absoluteScript(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path)]
        if let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !f.isEmpty {
            let root = URL(fileURLWithPath: f)
            candidates.append(root.deletingLastPathComponent().appendingPathComponent(path))
            if path.hasPrefix("fixtures/") { candidates.append(root.appendingPathComponent(String(path.dropFirst("fixtures/".count)))) }
            candidates.append(root.appendingPathComponent(path))
        }
        return (candidates.first { fm.fileExists(atPath: $0.path) } ?? candidates[0]).standardizedFileURL.path
    }

    /// The mic click (MicButton, after the permission check): the bar shows now; capture starts in the helper.
    /// `locale` / `deviceUID` = Settings › Voice › Spoken language / Microphone (M3.T08; read at each start, R-053 AC2).
    public func start(incognito: Bool, chatID: String?, locale: String? = nil, deviceUID: String? = nil) {
        guard !phase.isActive, !calls.isActive else { return }  // P2-8: a call holds the mic
        let click = Self.signposter.beginInterval("dictation.click")
        let id = UUID()
        requestID = id
        mode = nil
        stopSent = false
        final = nil
        partial = ""
        levels = []
        levelUpdates = 0
        self.chatID = chatID
        startedAt = Date()
        phase = .recording
        Self.signposter.endInterval("dictation.click", click)
        Self.signposter.emitEvent("dictation.indicator")
        var url: URL?
        if !incognito {
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            url = tempDir.appendingPathComponent("\(id.uuidString).m4a")
        }
        recordingURL = url
        let start = DictationStart(requestID: id, locale: locale, deviceUID: deviceUID, recordingURL: url,
                                   scriptedInput: scriptedInput)
        let engine = engine, models = models()
        isBasic = models.slots[.stt] == nil  // VoiceBackendSelector: the helper picks SpeechAnalyzer for this session
        pump = Task { [weak self] in
            // Register the installed voice models first (the helper answers `done`), then open the dictation.
            for await _ in engine.voiceStream(.models(models)) {}
            guard !Task.isCancelled, self?.requestID == id else { return }
            for await batch in engine.voiceStream(.dictationStart(start)) {
                guard let self else {
                    engine.cancel(id)  // P1-6: the controller went away mid-dictation: stop the helper's capture
                    return
                }
                self.apply(batch.items, id: id)
            }
            self?.streamEnded(id)
        }
    }

    /// P1-6: the composer's window closes (or its host goes away): a running dictation is cancelled in the helper,
    /// its audio and text are dropped.
    public func teardown() {
        guard let id = requestID else { return }
        if phase.isActive {
            mode = .cancel
            phase = .cancelled
            partial = ""
            sendStop(id)
        }
        engine.cancel(id)
        pump?.cancel()
        pump = nil
        requestID = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    /// ■ stop-to-review, ↑ send-now, × cancel.
    public func stop(_ mode: DictationStop.Mode) {
        guard let id = requestID else { return }
        switch phase {
        case .recording: break
        case .finalizing where mode == .cancel: break
        default: return
        }
        self.mode = mode
        phase = mode == .cancel ? .cancelled : .finalizing
        if mode == .cancel { partial = "" }
        sendStop(id)
    }

    private func sendStop(_ id: UUID) {
        guard let mode, !stopSent else { return }
        stopSent = engine.voiceSend(.dictationStop(DictationStop(requestID: id, mode: mode)))
    }

    func apply(_ items: [StreamItem], id: UUID) {
        guard id == requestID else { return }
        if !stopSent, mode != nil { sendStop(id) }  // the first send can precede the connection
        for item in items {
            switch item {
            case .voice(.audioLevel(let l)):
                levels.append(l)
                if levels.count > Self.waveformCount { levels.removeFirst(levels.count - Self.waveformCount) }
                levelUpdates += 1
            case .voice(.partialTranscript(let t)):
                if phase == .recording || phase == .finalizing { partial = t }
            case .voice(.finalTranscript(let f)):
                final = f
                finish(f)
            case .engine(.error(let e)):
                if phase != .cancelled { phase = .failed(e.fullCode) }
            default: break
            }
        }
    }

    private func finish(_ f: FinalTranscript) {
        guard mode != .cancel else { return }
        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        if text.isEmpty {
            phase = .empty  // R-050 AC3: back to an empty composer, no error, no toast
            return
        }
        phase = .done(text)
        if mode == .sendNow { onSendNow?(text) } else { onReview?(text) }
    }

    func streamEnded(_ id: UUID) {
        guard id == requestID else { return }
        pump = nil
        requestID = nil
        if phase.isActive { phase = .failed("voice.ended") }
        if let url = recordingURL, let f = final, !f.text.isEmpty, mode != .cancel,
           FileManager.default.fileExists(atPath: url.path) {
            onRecording?(Recording(audio: url, transcript: f.text, language: f.language, engine: f.engine, chatID: chatID))
        } else if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Snapshots and previews: a fixed bar state, no helper.
    public func setPreviewState(_ phase: Phase, partial: String = "", levels: [Float] = [], startedAt: Date? = Date(),
                                isBasic: Bool = false) {
        self.phase = phase
        self.isBasic = isBasic
        self.partial = partial
        self.levels = levels
        self.startedAt = startedAt
    }
    #endif

    /// Back to idle after the composer consumed the result (the bar hides).
    public func reset() {
        guard !phase.isActive else { return }
        phase = .idle
        partial = ""
        levels = []
        startedAt = nil
    }
}

/// Length of a recorded dictation (Recent recordings `duration_ms`).
public enum RecordingDuration {
    public static func seconds(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}
