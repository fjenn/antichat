// M3.T04 (R-281 AC1; R-054 groundwork): read aloud, app side. One speech at a time app-wide; the helper speaks
// (contract 1). The backend is decided when the speech starts from the registered voice models
// (VoiceBackendSelector): no verified Voice pack → Basic voice (system voice, label "Basic voice"). Clicking the
// speaking message again stops it (`SpeakStop`). M3.T07 (R-054, IS-9): Kokoro with the verified pack; the button is a
// spinner from the click until the first chunk's audio starts (`ttsStarted`), then ‖ / stop in place
// (`msg.stopReading`); signposts `readAloud.click` → `tts.firstSample` (helper) for NFR-V8.
// M3 review P1-2: a stop before the speech plays is never lost — a speech stopped during the models step is not
// opened at all, and one stopped while Kokoro loads is cancelled in the helper (which keeps the stop until it plays).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
public final class ReadAloudController {
    /// The message being read, nil when silent.
    public private(set) var speakingID: String?
    /// The current speech runs on Basic voice.
    public private(set) var isBasic = false
    /// Between the click and the first audio (the spinner, IS-9).
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    @ObservationIgnored var engine: (any EngineService)?
    @ObservationIgnored var models: @MainActor () -> VoiceModelSet = { VoiceModelSet(slots: [:]) }
    @ObservationIgnored private var requestID: UUID?

    public static let shared = ReadAloudController()
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")

    public init() {}

    /// The window host wires the engine and the registered-model source once.
    public var isConfigured: Bool { engine != nil }

    public func configure(engine: any EngineService, models: @escaping @MainActor () -> VoiceModelSet) {
        self.engine = engine
        self.models = models
    }

    /// `codeOmitted` = the localized `voice.codeOmitted` sentence spoken in place of each code block.
    /// `voiceID` / `rate` = Settings › Voice (M3.T08, R-053 AC2: read at each read aloud, so a change applies to the
    /// next one without a restart); `purpose: .preview` = the Voice row's [Preview].
    public func toggle(id: String, text: String, codeOmitted: String? = nil, voiceID: String = "", rate: Double = 1,
                       purpose: Speak.Purpose = .readAloud) {
        if speakingID == id { return stop() }
        stop()
        guard let engine, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Self.signposter.emitEvent("readAloud.click")
        let set = models()
        let request = Speak(text: text, voiceID: voiceID, rate: Float(min(1.5, max(0.75, rate))), purpose: purpose,
                            codeOmitted: codeOmitted)
        requestID = request.requestID
        speakingID = id
        isBasic = set.slots[.tts] == nil
        isLoading = true
        lastError = nil
        Task { [weak self] in
            for await _ in engine.voiceStream(.models(set)) {}
            guard self?.requestID == request.requestID else { return }  // stopped meanwhile: never opened
            for await b in engine.voiceStream(.speak(request)) {
                for item in b.items {
                    switch item {
                    case .voice(.ttsStarted):
                        if self?.requestID == request.requestID { self?.isLoading = false }
                    case .engine(.error(let x)): self?.lastError = x.fullCode
                    default: break
                    }
                }
            }
            guard let self, self.requestID == request.requestID else { return }
            self.speakingID = nil
            self.requestID = nil
            self.isLoading = false
        }
    }

    public func stop() {
        guard let id = requestID else { return }
        _ = engine?.voiceSend(.speakStop(SpeakStop(requestID: id)))
        engine?.cancel(id)  // a speech still waiting for its stream to open, or for Kokoro, ends too
        requestID = nil
        speakingID = nil
        isLoading = false
    }
}
