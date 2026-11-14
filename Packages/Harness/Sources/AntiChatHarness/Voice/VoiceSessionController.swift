// M3.T11 (R-052; S-16, IS-9): the app side of a voice conversation. Owns the helper session stream
// (`VoiceSessionStart` … `VoiceSessionEnd`), renders its `VoiceEvent`s into the overlay's state, and hands the turns to
// `VoiceTurnBridge` (the chat: user messages, spoken replies, barge-in truncation).
//   connecting → listening ⇄ userSpeaking → thinking → speaking → listening …; barge-in snaps speaking → userSpeaking in
//   the same update as `ttsStopped(.bargeIn)`; mic lost → error(`voice.noDevice`).
// Background (R-052 AC6): the session keeps running when the window is not key or the app is hidden — the helper keeps
// the audio engine; App Nap is held off with `ProcessInfo.beginActivity` for the session; `isActive` drives the menu bar
// call indicator. Push-to-talk (AC2): `pttDown` / `pttUp` (Space while the composer field is not first responder).
// An empty session (no user utterance) writes nothing: nothing reaches the chat until a final transcript.
// M3 review: End while connecting cancels the request and never opens the session (P0-1); mute pressed while connecting
// is sent as soon as the session stream is open, ahead of anything it hears (P1-1); a push-to-talk Space released
// after the window lost key still ends the turn (`releasePushToTalk`, P2-7).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
public final class VoiceSessionController {
    public enum Phase: Equatable, Sendable {
        case idle, connecting, listening, userSpeaking, thinking, speaking
        case error(String)

        public var isLive: Bool { self != .idle && !isError }
        public var isError: Bool { if case .error = self { true } else { false } }
    }

    public private(set) var phase: Phase = .idle
    /// Input level, dBFS (orb while listening / user speaking).
    public private(set) var inputLevel: Float = -120
    /// The partial transcript while the user speaks; the spoken sentence while the assistant speaks (R-052 AC5).
    public private(set) var caption = ""
    public private(set) var micMuted = false
    public private(set) var speakerMuted = false
    public private(set) var mode: VoiceSessionStart.Mode = .handsFree
    /// Barge-ins in this session (UI tests, the orb's snap).
    public private(set) var bargeIns = 0
    public private(set) var lastError: String?
    /// The chat the session talks into.
    public private(set) var chatID: String?
    /// F3 (round 66): the reply of the current spoken turn. The model writes text much faster than the helper
    /// synthesises its first audio, so the transcript showed the whole reply under "Thinking…". The transcript holds
    /// this reply's text while the session is still thinking (`holdsReply`) and shows it when speaking starts (or the
    /// session leaves thinking any other way: barge-in, no audio, error, End).
    public private(set) var voicedReplyID: String?

    /// The transcript hides reply `id`'s text for now: it is this turn's reply and nothing of it is spoken yet.
    public func holdsReply(_ id: String) -> Bool { phase == .thinking && voicedReplyID == id }

    /// The menu bar call indicator exists exactly while this is true (`CallIndicatorExtra`).
    public var isActive: Bool { phase.isLive || phase == .connecting }

    @ObservationIgnored public let bridge: VoiceTurnBridge
    @ObservationIgnored private let engine: any EngineService
    @ObservationIgnored private let models: @MainActor () -> VoiceModelSet
    @ObservationIgnored private let scriptedInput: String?
    @ObservationIgnored private let fakeAudio: String?
    /// M3.T12 (R-280 AC2): the session fell back to half duplex (no barge-in by voice): the overlay shows
    /// `voice.headphones` once (`HeadphonesHint`).
    public private(set) var halfDuplex = false
    @ObservationIgnored private var requestID: UUID?
    /// The session stream is open in the helper (`sessionStart` sent): controls go to the wire from now on.
    @ObservationIgnored private var sessionOpened = false
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var pttIsDown = false
    @ObservationIgnored private let tier: DeviceTier
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")

    public init(engine: any EngineService, models: @escaping @MainActor () -> VoiceModelSet,
                scriptedInput: String? = LaunchOptions.current.scriptedVoiceScript, tier: DeviceTier = .current(),
                fakeAudio: String? = LaunchOptions.current.fakeAudio) {
        self.engine = engine
        self.fakeAudio = fakeAudio
        self.tier = tier
        self.models = models
        self.scriptedInput = scriptedInput.map(DictationController.absoluteScript)
        var sendRef: ((VoiceSessionControl.Action) -> Void)?
        bridge = VoiceTurnBridge { sendRef?($0) }
        sendRef = { [weak self] action in self?.send(action) }
        bridge.onReplyStarted = { [weak self] id in self?.voicedReplyID = id }
    }

    /// Starts a conversation into `port` (the chat). `voiceID` / `rate` / `mode` / `locale` = Settings › Voice.
    public func start(port: any VoiceChatPort, chatID: String?, voiceID: String, rate: Double, mode: VoiceSessionStart.Mode,
                      locale: String?, codeOmitted: String?, duckOthers: Bool = true) {
        guard !isActive else { return }
        Self.signposter.emitEvent("voice.sessionClick")
        bridge.port = port
        self.chatID = chatID
        self.mode = mode
        micMuted = false
        speakerMuted = false
        caption = ""
        bargeIns = 0
        lastError = nil
        halfDuplex = false
        phase = .connecting
        VoiceCalls.shared.current = self
        let start = VoiceSessionStart(chatID: UUID(), mode: mode, locale: locale, voiceID: voiceID,
                                      rate: Float(min(1.5, max(0.75, rate))), duckOthers: duckOthers,
                                      scriptedInput: scriptedInput, codeOmitted: codeOmitted, fakeAudio: fakeAudio)
        requestID = start.requestID
        // T1: the chat context is capped at 8K for the session (model-matrix §2.3 mitigation 1).
        if tier == .t1 { ContextPolicy.voiceSessionCap = 8192 }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Voice conversation")
        let set = models()
        let engine = engine
        sessionOpened = false
        pump = Task { [weak self] in
            for await _ in engine.voiceStream(.models(set)) {}
            // P0-1: ended (or the window went) while the models registered: the session is never opened.
            guard !Task.isCancelled, let me = self, me.requestID == start.requestID else { return }
            let stream = engine.voiceStream(.sessionStart(start))
            me.opened(start.requestID)
            for await batch in stream {
                guard let self, self.requestID == start.requestID else { return }
                for item in batch.items { self.apply(item) }
            }
            guard let self, self.requestID == start.requestID else { return }
            self.finished()
        }
    }

    /// P1-1: the controls pressed while connecting (the mutes) go out right behind `sessionStart`; the helper applies
    /// them before the session hears anything.
    private func opened(_ id: UUID) {
        sessionOpened = true
        if micMuted { send(.muteMic) }
        if speakerMuted { send(.muteSpeaker) }
        if pttIsDown { send(.pttDown) }
    }

    /// × End (`voice.end`), or the menu bar's End.
    public func end() {
        guard let id = requestID else { return }
        // P0-1: End at any moment, also while connecting. `sessionEnd` ends an open session (the helper also keeps an
        // End that arrives while it is still leasing the models); the cancel closes the request whatever stage it is
        // in; the pump stops listening.
        if sessionOpened { _ = engine.voiceSend(.sessionEnd(VoiceSessionEnd(requestID: id))) }
        engine.cancel(id)
        pump?.cancel()
        finished()
    }

    public func toggleMic() {
        micMuted.toggle()
        send(micMuted ? .muteMic : .unmuteMic)
    }

    public func toggleSpeaker() {
        speakerMuted.toggle()
        send(speakerMuted ? .muteSpeaker : .unmuteSpeaker)
    }

    /// Space down / up in push-to-talk mode.
    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Visual QA (`-VisualQAProbe`, M3.T14 captures): show the overlay in `phase` without a helper session.
    public func debugPresent(_ phase: Phase, caption: String = "", halfDuplex: Bool = false, level: Float = -30) {
        self.phase = phase
        self.caption = caption
        self.halfDuplex = halfDuplex
        inputLevel = level
        VoiceCalls.shared.current = phase == .idle ? nil : self
    }
    #endif

    public func pttDown() {
        guard mode == .pushToTalk, phase.isLive, !pttIsDown else { return }
        pttIsDown = true
        send(.pttDown)
    }

    public func pttUp() {
        guard mode == .pushToTalk, pttIsDown else { return }
        pttIsDown = false
        send(.pttUp)
    }

    /// P2-7: the window lost key (or the app went inactive) while Space was held: its key-up will not reach us.
    public func releasePushToTalk() { pttUp() }

    public var isPushToTalkHeld: Bool { pttIsDown }

    /// The running pump (tests wait on it).
    var currentPump: Task<Void, Never>? { pump }

    private func send(_ action: VoiceSessionControl.Action) {
        guard let id = requestID, sessionOpened else { return }  // before the stream opens, `opened` sends the state
        _ = engine.voiceSend(.sessionControl(VoiceSessionControl(requestID: id, action: action)))
    }

    func apply(_ item: StreamItem) {
        switch item {
        case .voice(let e):
            bridge.handle(e)
            switch e {
            case .voiceState(let s):
                if s != .thinking, s != .halfDuplex { voicedReplyID = nil }  // F3: spoken (or over): the text shows
                switch s {
                case .listening: phase = .listening; caption = ""
                case .transcribing: phase = .userSpeaking
                case .thinking: phase = .thinking; caption = ""
                case .speaking: phase = .speaking
                case .halfDuplex: halfDuplex = true  // a mode switch, not a phase (M3.T12)
                case .idle: break
                }
            case .audioLevel(let l): inputLevel = l
            case .partialTranscript(let t): if phase == .userSpeaking || phase == .listening { caption = t }
            case .finalTranscript: caption = ""
            case .speakingText(let t): caption = Self.caption(after: caption, chunk: t)
            case .ttsStopped(_, .bargeIn):
                voicedReplyID = nil
                bargeIns += 1
                phase = .userSpeaking  // the orb snaps to listening in the same frame (IS-9)
                caption = ""
                Self.signposter.emitEvent("voice.bargeInSnap")
            default: break
            }
        case .engine(.error(let x)):
            voicedReplyID = nil
            lastError = x.fullCode
            phase = .error(x.code == "noDevice" ? "voice.noDevice" : x.fullCode)
        case .engine(.done):
            break
        default:
            break
        }
    }

    private func finished() {
        requestID = nil
        sessionOpened = false
        pump = nil
        pttIsDown = false
        if tier == .t1 { ContextPolicy.voiceSessionCap = nil }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if !phase.isError { phase = .idle }
        caption = ""
        voicedReplyID = nil
        if VoiceCalls.shared.current === self { VoiceCalls.shared.current = nil }
        onEnded?()
    }

    /// The call ended (End, an error, the helper's terminal): the window detaches its chats from the bridge.
    @ObservationIgnored public var onEnded: (() -> Void)?

    /// Snapshot / preview state (no helper): the overlay's look in `phase`.
    public func setPreviewState(_ phase: Phase, caption: String = "", level: Float = -30, micMuted: Bool = false,
                                speakerMuted: Bool = false, mode: VoiceSessionStart.Mode = .handsFree) {
        self.phase = phase
        self.caption = caption
        inputLevel = level
        self.micMuted = micMuted
        self.speakerMuted = speakerMuted
        self.mode = mode
    }

    /// Dismisses an error state (the error's [End]).
    public func dismissError() {
        if requestID != nil { end() }
        phase = .idle
    }

    /// The caption once spoken chunk `chunk` starts (R-052 AC5: "the current spoken sentence while speaking"). The
    /// helper speaks a sentence's first clause as a chunk of its own (time to first audio), so the caption showed half
    /// a sentence, then the rest (Q-015 r7, VoiceToolsTests): a chunk that continues a sentence adds to it; a chunk
    /// after a sentence's end starts the caption afresh.
    nonisolated static func caption(after previous: String, chunk: String) -> String {
        let chunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return previous }
        guard let last = prev.last, !".!?…。！？".contains(last) else { return chunk }
        return prev + " " + chunk
    }
}

/// M3.T11 (R-052 AC6): the app's running voice call, for the menu bar indicator (`CallIndicatorExtra`, replaced by
/// M8's full MenuBarExtra, which keeps this state). One call at a time app-wide.
@MainActor
@Observable
public final class VoiceCalls {
    public static let shared = VoiceCalls()
    public var current: VoiceSessionController?
    /// Brings the call's window and chat to the front ("Show chat"); set by the window that started the call.
    @ObservationIgnored public var showChat: (@MainActor () -> Void)?
    public var isActive: Bool { current?.isActive ?? false }
    /// M3 review P2-5 / P2-8: the dictations recording or finalizing in any window (one per composer).
    public private(set) var dictations: Set<ObjectIdentifier> = []
    /// A dictation runs in some window.
    public var isDictating: Bool { !dictations.isEmpty }
    /// The microphone is held by a dictation or a call somewhere in the app (Settings › Voice's meter yields it).
    public var micInUse: Bool { isActive || isDictating }
    public init() {}

    func dictation(_ id: ObjectIdentifier, active: Bool) {
        if active { dictations.insert(id) } else { dictations.remove(id) }
    }
}
