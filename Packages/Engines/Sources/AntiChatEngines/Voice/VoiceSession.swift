// M3.T10 (R-052, R-282; G-037, G-038; P-media-03): one hands-free / push-to-talk voice conversation in the helper
// (contract 1: the helper owns capture, VAD, STT, TTS and playback; the app sends `VoiceSessionControl`s and renders
// `VoiceEvent`s). Pipeline per 32 ms input frame:
//   capture (VPIO graph, or ScriptedVoice with VPIO bypassed) → level → `TurnDetector` (Silero + smart-turn + EOU + cap)
//   → eager STT (a recogniser opened at the speech onset, fed the pre-roll and every frame, finished at the turn end)
//   → `finalTranscript` (the app appends the user message and starts a normal chat turn)
//   while speaking: the same Silero probability → `BargeInDetector` → pause / resume / stop-and-truncate.
// The reply: the app streams the assistant text (`speak` deltas, then `speakEnd`) → `VoiceReplyText` (clause chunks,
// Markdown never spoken) → Kokoro → the session's output sink; `SpokenSpanTracker` maps the played clock to the stored
// text at a stop (`spokenSpan`). The pure transitions live in `VoiceSessionMachine`; this actor performs the effects.
// Signposts: `voice.bargeOnset`, `tts.silent` (output paused), `tts.firstSample` (Kokoro), and the M3.T09 three.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import os
import SpeechSwiftVendored
import Synchronization

/// What a session needs from the outside world (models and devices), injectable for tests.
public struct VoiceSessionParts: @unchecked Sendable {  // the VAD and smart-turn objects are used by the session actor only
    public var capture: any AudioCaptureSource
    public var live: Bool
    public var vad: any StreamingVADProvider
    public var smartTurn: (any TurnCompletionProvider)?
    /// A fresh recogniser for one user turn (+ its leases).
    public var recogniser: @Sendable () async throws -> (backend: any SpeechBackend, leases: [VoiceModelLease])
    /// A fresh synthesiser for one reply, writing into `TTSPlayback`.
    public var synthesiser: @Sendable (TTSPlayback) -> any TTSBackend
    public var sink: any VoiceOutputSink
    /// Session-long leases (keep the models resident), released at the end.
    public var leases: [VoiceModelLease]
    public var thresholds: TurnThresholds
    /// A-M3-T09c: synthesise one chunk ahead of time (text, voice id, rate); the reply's synthesiser reuses it only
    /// for the same chunk text (`PresynthesizingSynth`). Nil: no speculative synthesis.
    public var presynthesize: (@Sendable (String, String, Float) -> Void)?
    /// M3.T12: the output route, whether VPIO was requested, and whether it failed to start (half duplex).
    public var route: VoiceAudioRoute = .injected
    public var voiceProcessing = false
    public var aecFailed: @Sendable () -> Bool = { false }
    /// M3.T12 (R-280 AC3): the ducking the live graph applied (`"min"`; nil = none), reported once at the start.
    public var duckingLevel: @Sendable () -> String? = { nil }
    /// M3.T12 (review finding 11): the route and VPIO plan now (they change with the device); nil = fixed.
    public var currentPlan: (@Sendable () -> (route: VoiceAudioRoute, voiceProcessing: Bool))?
    /// M3 review P2-3: registers the session's handler for a lost capture graph (a rebuild after a device change that
    /// failed); nil = the input cannot be lost (injected).
    public var watchDevice: (@Sendable (@escaping @Sendable (Error) -> Void) -> Void)?

    public init(capture: any AudioCaptureSource, live: Bool, vad: any StreamingVADProvider,
                smartTurn: (any TurnCompletionProvider)?,
                recogniser: @escaping @Sendable () async throws -> (backend: any SpeechBackend, leases: [VoiceModelLease]),
                synthesiser: @escaping @Sendable (TTSPlayback) -> any TTSBackend, sink: any VoiceOutputSink,
                leases: [VoiceModelLease] = [], thresholds: TurnThresholds = .standard,
                presynthesize: (@Sendable (String, String, Float) -> Void)? = nil,
                route: VoiceAudioRoute = .injected, voiceProcessing: Bool = false,
                aecFailed: @escaping @Sendable () -> Bool = { false },
                duckingLevel: @escaping @Sendable () -> String? = { nil },
                currentPlan: (@Sendable () -> (route: VoiceAudioRoute, voiceProcessing: Bool))? = nil) {
        self.currentPlan = currentPlan
        self.duckingLevel = duckingLevel
        self.presynthesize = presynthesize
        self.route = route
        self.voiceProcessing = voiceProcessing
        self.aecFailed = aecFailed
        self.capture = capture
        self.live = live
        self.vad = vad
        self.smartTurn = smartTurn
        self.recogniser = recogniser
        self.synthesiser = synthesiser
        self.sink = sink
        self.leases = leases
        self.thresholds = thresholds
    }
}

/// Per-session numbers for the perf probes (host times, ns; `VoiceAudioSignposts.now()`).
public struct VoiceSessionTimings: Sendable, Equatable {
    public var lastVoiced: [UInt64] = []
    public var turnEnded: [UInt64] = []
    public var finalTranscript: [UInt64] = []
    public var firstSample: [UInt64] = []
    public var bargeOnset: [UInt64] = []
    public var ttsSilent: [UInt64] = []
    /// Input sample of each confirmed barge-in onset (the fixture's own timeline).
    public var bargeOnsetSample: [Int] = []
    public var ttsSilentSample: [Int] = []
}

final class ChunkLookup: Sendable {
    let m = Mutex<[Int: SpokenChunk]>([:])
}

/// A Mutex that closures can capture (the Mutex itself is not copyable).
final class LockedBox<T: Sendable>: Sendable {
    let m: Mutex<T>
    init(_ value: T) { m = Mutex(value) }
    func withLock<R>(_ body: (inout T) -> R) -> R { m.withLock { body(&$0) } }
}

public actor VoiceSession {
    public let start: VoiceSessionStart
    private let parts: VoiceSessionParts
    private let emit: VoiceEmit
    private var machine = VoiceSessionMachine()
    private let detector: TurnDetector
    private var barge = BargeInDetector()
    private var frames: AsyncStream<[Float]>.Continuation?
    private var pump: Task<Void, Never>?
    private var inputSamples = 0
    /// The last 2 s of input: the STT pre-roll from the speech onset.
    private var ring: [Float] = []
    private static let ringSamples = 32_000

    // The user turn being recognised.
    private var recogniser: (backend: any SpeechBackend, leases: [VoiceModelLease], transcriber: EagerTurnTranscriber)?
    private var opening: Task<Void, Never>?
    private var pendingAudio: [Float] = []
    /// NFR-V1: the transcript taken at the turn's last pause (`.paused`) and the voiced sample it covers; it is the
    /// final when the turn ends with nothing voiced after it, so the final follows the turn end at once.
    private var provisional: (voiced: Int, task: Task<FinalTranscript?, Never>)?
    /// A pause heard while the recogniser was still opening (its voiced sample).
    private var pausePending: Int?
    private let eouFlag = LockedBox(false)
    private var pttHeld = false

    // The reply being spoken.
    private struct Reply {
        var turnID: UUID
        var text: VoiceReplyText
        var tracker = SpokenSpanTracker()
        let lookup = ChunkLookup()
        var feed: AsyncStream<TTSChunk>.Continuation
        var backend: any TTSBackend
        var task: Task<Void, Never>?
        var startedAudio = false
        var stopped = false
        /// The synthesiser's last played-time report (the sink restarts at 0 once a finished reply is flushed).
        var playedMs: Double = 0
    }
    private var reply: Reply?
    private let trackerBox = LockedBox(SpokenSpanTracker())
    private var voiceID: String
    private var rate: Float
    public private(set) var timings = VoiceSessionTimings()
    /// The played samples and chunk table at the last stop (AT-282 AC2 evidence; tests and probes).
    public private(set) var lastStopTrace: (played: Int, entries: [SpokenSpanTracker.Entry])?
    private var levelTick = 0
    /// M3.T12 (R-280 AC2): full / half duplex; the mic is gated while the reply plays and until this input sample.
    private var duplex: HalfDuplexPolicy
    private var gateUntilSample = 0
    private var firstChunkPlaying = false
    private var firstChunkBarged = false
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")

    /// M3 review P0-2 / P2-3: a failure the session cannot continue after (no recogniser, capture lost). The service
    /// ends the session (capture off, leases released), then sends the error as the stream's terminal.
    private let onFatal: (@Sendable (AntiChatError) -> Void)?

    public init(start: VoiceSessionStart, parts: VoiceSessionParts, emit: @escaping VoiceEmit,
                onFatal: (@Sendable (AntiChatError) -> Void)? = nil) {
        self.start = start
        self.parts = parts
        self.emit = emit
        self.onFatal = onFatal
        voiceID = start.voiceID
        rate = start.rate
        detector = TurnDetector(vad: parts.vad, smartTurn: parts.smartTurn, thresholds: parts.thresholds)
        duplex = HalfDuplexPolicy(route: parts.route)
    }

    /// M3.T12: the session runs half duplex.
    public var isHalfDuplex: Bool { machine.halfDuplex }

    public var state: VoiceState { machine.state }
    public var isPushToTalk: Bool { start.mode == .pushToTalk }

    // MARK: - Lifecycle

    public func begin() throws {
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        frames = cont
        pump = Task { [weak self] in
            for await frame in stream { await self?.ingest(frame) }
        }
        perform(machine.next(.start))
        do {
            try parts.capture.start { samples in cont.yield(samples) }
        } catch {
            perform(machine.next(.end))
            throw error
        }
        if let level = parts.duckingLevel() {
            emit([.voice(.signpost(name: "audio.ducking.\(level)", hostNs: VoiceAudioSignposts.now()))])
        }
        if let reason = duplex.started(voiceProcessing: parts.voiceProcessing, aecStarted: !parts.aecFailed()) {
            enterHalfDuplex(reason)
        }
        parts.watchDevice? { [weak self] error in
            Task { await self?.fatal(.voice("noDevice", "capture lost: \(error)")) }
        }
    }

    /// M3 review P0-2 / P2-3: the session cannot go on. Never a terminal from inside a running session: the service
    /// ends it first (without a service — tests — the session ends itself, then reports).
    func fatal(_ error: AntiChatError) async {
        guard !ended else { return }
        AppLog.log(.voice, .error, "voice session: ending on \(error.fullCode)")
        if let onFatal { return onFatal(error) }
        await end()
        emit([.engine(.error(error))])
    }

    /// M3.T12 step 2: the mic is gated while the assistant speaks (+ 300 ms), barge-in by voice is off, and the app
    /// shows `voice.headphones` once (`voiceState(.halfDuplex)`).
    private func enterHalfDuplex(_ reason: HalfDuplexPolicy.Reason) {
        guard !machine.halfDuplex else { return }
        perform(machine.next(.setHalfDuplex(true)))
        AppLog.log(.voice, .info, "voice session: half duplex (\(reason.rawValue), route \(parts.route.rawValue))")
        emit([.voice(.voiceState(.halfDuplex)), .voice(.signpost(name: "voice.halfDuplex.\(reason.rawValue)", hostNs: VoiceAudioSignposts.now()))])
    }

    /// A route / device change (review finding 11): a new route is judged afresh; VPIO that failed on a rebuild
    /// switches to half duplex.
    private func recheckDuplex() {
        let plan = parts.currentPlan?() ?? (route: parts.route, voiceProcessing: parts.voiceProcessing)
        if plan.route != duplex.route {
            duplex = HalfDuplexPolicy(route: plan.route)
            if machine.halfDuplex, plan.route.echoFree { perform(machine.next(.setHalfDuplex(false))) }
        }
        guard !machine.halfDuplex else { return }
        if let reason = duplex.started(voiceProcessing: plan.voiceProcessing, aecStarted: !parts.aecFailed()) {
            enterHalfDuplex(reason)
        }
    }

    /// Half duplex: the reply is playing or its 300 ms tail has not passed.
    private var micGated: Bool {
        machine.halfDuplex && !pttHeld && (machine.state == .speaking || inputSamples < gateUntilSample)
    }

    private var ended = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once `end()` ran.
    public func untilEnded() async {
        if ended { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    /// Ends the session: capture off, speech flushed, every lease released; the stream's terminal follows.
    public func end() async {
        guard !ended else { return }
        ended = true
        defer {
            for w in endWaiters { w.resume() }
            endWaiters.removeAll()
        }
        perform(machine.next(.end))
        parts.capture.stop()
        frames?.finish()
        pump?.cancel()
        if let opening { await opening.value }  // `opened` sees `ended` and closes what it opened
        if let r = recogniser {
            await r.transcriber.cancel()
            for l in r.leases { await l.release() }
            recogniser = nil
        }
        stopReply(reason: .stopped, report: false)
        parts.sink.flush()
        for l in parts.leases { await l.release() }
    }

    public func control(_ action: VoiceSessionControl.Action) async {
        switch action {
        case .muteMic: perform(machine.next(.muteMic(true)))
        case .unmuteMic: perform(machine.next(.muteMic(false)))
        case .muteSpeaker: perform(machine.next(.muteSpeaker(true)))
        case .unmuteSpeaker: perform(machine.next(.muteSpeaker(false)))
        case .pttDown: await pttDown()
        case .pttUp: await pttUp()
        case .speak(let text, let turnID): speak(text, turnID: turnID)
        case .speakEnd(let turnID): speakEnd(turnID)
        case .flush:
            // A typed message / a new turn replaces the current reply: stop it, report what was heard.
            if machine.state == .speaking || machine.state == .thinking {
                stopReply(reason: .flushed, report: true)
                perform(machine.next(.replyDone))
            }
        case .setRate(let r): rate = min(1.5, max(0.75, r))
        case .setVoice(let v): voiceID = v
        case .speculate(let text): speculate(text)
        }
    }

    /// The first chunk last synthesised ahead of time (A-M3-T09c).
    private var presynthesized: String?

    /// A-M3-T09c: the speculative reply so far → its first chunk (the reply's own chunker, so the adopted reply's
    /// chunk 0 is the same text) is synthesised ahead of time. Nothing plays from here.
    private func speculate(_ text: String) {
        guard let presynthesize = parts.presynthesize, reply == nil else { return }
        var chunker = VoiceReplyText(codeOmitted: start.codeOmitted ?? SpeakableText.defaultCodeOmitted)
        guard let first = chunker.feed(text).first, first.index == 0, first.text != presynthesized else { return }
        presynthesized = first.text
        presynthesize(first.text, voiceID, rate)
    }

    // MARK: - Input

    func ingest(_ frame: [Float]) async {
        guard machine.state != .idle else { return }
        inputSamples += frame.count
        levelTick += 1
        if levelTick % 31 == 0 { recheckDuplex() }  // about once a second
        emit([.voice(.audioLevel(machine.micMuted ? -120 : Float(rmsDBFS(frame))))])
        guard !machine.micMuted else { return }
        // Half duplex: what the mic hears while the reply plays is the reply (no echo cancellation): silence instead.
        let heard = micGated ? [Float](repeating: 0, count: frame.count) : frame
        ring.append(contentsOf: heard)
        if ring.count > Self.ringSamples { ring.removeFirst(ring.count - Self.ringSamples) }
        let events = detector.process(samples: heard)
        if firstChunkPlaying { duplex.firstChunkFrame(probability: detector.lastSpeechProbability) }
        if machine.state == .speaking || machine.state == .thinking {
            switch barge.feed(probability: detector.lastSpeechProbability, endSample: inputSamples) {
            case .candidate(let onset):
                let now = VoiceAudioSignposts.now()
                let onsetNs = now - UInt64(Double(inputSamples - onset) / 16_000 * 1e9)
                timings.bargeOnset.append(onsetNs)
                sign("voice.bargeOnset", onsetNs)
                Self.signposter.emitEvent("voice.bargeOnset")
                perform(machine.next(.bargeCandidate))
                if machine.outputPaused {
                    let silentNs = VoiceAudioSignposts.now()
                    timings.ttsSilent.append(silentNs)
                    sign("tts.silent", silentNs)
                    timings.ttsSilentSample.append(inputSamples)
                    Self.signposter.emitEvent("tts.silent")
                }
            case .confirmed(let onset):
                if firstChunkPlaying { firstChunkBarged = true }
                timings.bargeOnsetSample.append(onset)
                perform(machine.next(.bargeConfirmed))
                // Push-to-talk: the voice stopped the reply, but only Space opens a turn.
                if isPushToTalk, !pttHeld { perform(machine.next(.abandonTurn)) }
            case .falseAlarm:
                perform(machine.next(.bargeFalseAlarm))
            case .none: break
            }
        }
        if recogniser != nil || opening != nil { feedRecogniser(heard) }
        for event in events { await handle(event) }
        if eouFlag.withLock({ f in defer { f = false }; return f }), !isPushToTalk, let e = detector.endOfUtterance() {
            await handle(e)
        }
    }

    private func handle(_ event: TurnDetectorEvent) async {
        switch event {
        case .speechStarted(let sample):
            guard !isPushToTalk else { return }
            if machine.state == .listening { perform(machine.next(.speechStarted)) }
            provisional = nil
            pausePending = nil
            presynthesized = nil  // a new turn: its speculation may start with the same words again (finding 12a)
            openRecogniser(from: sample)
        case .paused(let voiced):
            guard !isPushToTalk, machine.state == .transcribing else { return }
            takeProvisional(voiced: voiced)
        case .turnEnded(let reason, _, _, _, let host, let voicedHost):
            guard !isPushToTalk else { return }
            if machine.state == .transcribing {
                timings.turnEnded.append(host)
                if let voicedHost {
                    timings.lastVoiced.append(voicedHost)
                    sign("voice.lastVoicedFrame", voicedHost)
                }
                sign("voice.turnEnded", host)
                perform(machine.next(.turnEnded(reason)))
                await finishRecogniser(turn: event)
            } else {
                await cancelRecogniser()  // a turn heard while speaking that never became a barge-in
            }
        case .held, .failed:
            break
        }
    }

    /// The transcript of the turn so far (`.paused`); a recogniser still opening takes it as soon as it is open.
    private func takeProvisional(voiced: Int) {
        guard let r = recogniser else {
            pausePending = voiced
            return
        }
        pausePending = nil
        let transcriber = r.transcriber
        let emit = emit
        let task = Task { await transcriber.provisional() }
        provisional = (voiced, task)
        // Not inside `task`: a turn end decided by the transcript awaits `task` (finishRecogniser).
        Task { [weak self] in
            let t = await task.value
            // The app starts the reply speculatively from it (only while this turn is still open) …
            if let t, !TranscriptText.isNonSpeech(t.text), await self?.turnOpen(voiced: voiced) == true {
                emit([.voice(.provisionalTranscript(t.text))])
            }
            // … and stage 2's agreement reads it (a finished sentence may end the turn now; nil = no transcript at a
            // pause for this recogniser: agreement does not apply).
            await self?.provisionalReady(t?.text, voiced: voiced)
        }
    }

    private func openRecogniser(from sample: Int) {
        guard recogniser == nil, opening == nil else { return }
        let preroll = max(0, min(ring.count, inputSamples - sample + 8_000))  // + 0.5 s before the onset
        pendingAudio = Array(ring.suffix(preroll))
        let make = parts.recogniser
        let locale = start.locale.map(Locale.init(identifier:))
        let flag = eouFlag
        let emit = emit
        opening = Task { [weak self] in
            var made: (backend: any SpeechBackend, leases: [VoiceModelLease])?
            do {
                let (backend, leases) = try await make()
                made = (backend, leases)
                let t = EagerTurnTranscriber(backend: backend)
                // Live captions (R-052 AC5): the partial transcript under the orb while the user speaks.
                try await t.start(locale: locale, onEOU: { flag.withLock { $0 = true } },
                                  onPartial: { emit([.voice(.partialTranscript($0))]) })
                if let self {
                    await self.opened(backend: backend, leases: leases, transcriber: t)
                } else {
                    await t.cancel()
                    for l in leases { await l.release() }
                }
            } catch {
                // M3 review P0-2: a recogniser that failed to start gives its leases back.
                if let made {
                    await made.backend.cancel()
                    for l in made.leases { await l.release() }
                }
                await self?.openFailed(error)
            }
        }
    }

    private func opened(backend: any SpeechBackend, leases: [VoiceModelLease], transcriber: EagerTurnTranscriber) async {
        // Review finding 2: the session ended while the recogniser was opening: close it here.
        guard !ended else {
            opening = nil
            await transcriber.cancel()
            for l in leases { await l.release() }
            return
        }
        detector.expectsTranscript = true  // review finding 5: a failure earlier in the session is not sticky
        recogniser = (backend, leases, transcriber)
        opening = nil
        if !pendingAudio.isEmpty { transcriber.append(samples: pendingAudio) }
        pendingAudio = []
        if let voiced = pausePending, machine.state == .transcribing { takeProvisional(voiced: voiced) }
    }

    /// The turn whose pause was at `voiced` is still being heard.
    private func turnOpen(voiced: Int) -> Bool { !ended && machine.state == .transcribing && provisional?.voiced == voiced }

    private func provisionalReady(_ text: String?, voiced: Int) async {
        // A check that waited for the transcript may end the turn now (frames can arrive in bursts).
        if let end = detector.setTranscript(text, voicedSample: voiced) { await handle(end) }
    }

    private func openFailed(_ error: Error) async {
        detector.expectsTranscript = false  // no recogniser: turns end at the silence cap
        opening = nil
        pendingAudio = []
        AppLog.log(.voice, .error, "voice session: recogniser failed: \(error)")
        // M3 review P0-2: not a terminal from a running session (the app would drop its side while capture went on):
        // the session ends properly and the error is the stream's terminal.
        await fatal(error as? AntiChatError ?? .voice("sttFailed", "\(error)"))
    }

    private func feedRecogniser(_ frame: [Float]) {
        if let r = recogniser { r.transcriber.append(samples: frame) } else { pendingAudio += frame }
    }

    /// Waits for a recogniser still opening (its start is async), then finishes it on this turn.
    private func finishRecogniser(turn: TurnDetectorEvent) async {
        if let opening { await opening.value }
        let pending = provisional
        provisional = nil
        pausePending = nil
        guard let r = recogniser else {
            perform(machine.next(.finalReady(text: "")))
            return
        }
        recogniser = nil
        var final: FinalTranscript?
        var recogniserToClose: (EagerTurnTranscriber, [VoiceModelLease])?
        if let pending, case .turnEnded(_, _, _, let voiced, _, _) = turn, voiced == pending.voiced,
           let early = await pending.task.value {
            recogniserToClose = (r.transcriber, r.leases)
            // Nothing voiced since the pause: the provisional transcript is the final (same audio); the recogniser
            // closes after the final is out.
            final = early
            VoiceAudioSignposts.finalTranscript(turn: turn)
        } else {
            final = try? await r.transcriber.finish(turn: turn)
            for l in r.leases { await l.release() }
        }
        guard !ended else {  // review finding 2: nothing after End
            if let (transcriber, leases) = recogniserToClose {
                await transcriber.cancel()
                for l in leases { await l.release() }
            }
            return
        }
        let finalNs = VoiceAudioSignposts.now()
        timings.finalTranscript.append(finalNs)
        sign("voice.finalTranscript", finalNs)
        let text = final?.text ?? ""
        if let final, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit([.voice(.finalTranscript(final))])
        }
        perform(machine.next(.finalReady(text: text)))
        if let (transcriber, leases) = recogniserToClose {
            // Review finding 9: the early final is out; the recogniser closes now, before any next turn opens one
            // (its EOU model is shared: a late close would reset the next turn's).
            await transcriber.cancel()
            for l in leases { await l.release() }
        }
    }

    private func cancelRecogniser() async {
        provisional = nil
        pausePending = nil
        if let opening { await opening.value }
        guard let r = recogniser else { return }
        recogniser = nil
        await r.transcriber.cancel()
        for l in r.leases { await l.release() }
    }

    // MARK: - Push-to-talk (M3.T11 step 3)

    private func pttDown() async {
        guard isPushToTalk, !pttHeld else { return }
        pttHeld = true
        // Space is an explicit interrupt, whatever the duplex mode (review finding 3).
        if machine.state == .speaking || machine.state == .thinking { perform(machine.next(.pttInterrupt)) }
        if machine.state == .listening { perform(machine.next(.speechStarted)) }
        openRecogniser(from: inputSamples)
    }

    private func pttUp() async {
        guard isPushToTalk, pttHeld else { return }
        pttHeld = false
        guard machine.state == .transcribing else { return }
        let now = VoiceAudioSignposts.now()
        VoiceAudioSignposts.turnEnded(.ptt, at: now)
        let event = TurnDetectorEvent.turnEnded(reason: .ptt, startSample: 0, endSample: inputSamples,
                                                lastVoicedSample: inputSamples, hostTime: now, lastVoicedHostTime: nil)
        timings.turnEnded.append(now)
        perform(machine.next(.turnEnded(.ptt)))
        await finishRecogniser(turn: event)
    }

    // MARK: - Output

    private func speak(_ delta: String, turnID: UUID) {
        if reply?.turnID != turnID {
            if reply != nil {
                stopReply(reason: .flushed, report: true)
                // Q-015 r6 (VoiceToolsTests.testConnectionDuringVoice): the superseded segment ends its speaking state
                // too. An ApprovalCard answered by click while its spoken prompt still played left the machine in
                // `.speaking` with no reply: the guard below dropped every delta of the reply after the approval, and
                // the session sat on "Speaking" with the prompt's caption for good.
                if machine.state == .speaking { perform(machine.next(.replyDone)) }
            }
            guard machine.state == .thinking || machine.state == .listening else { return }
            perform(machine.next(.replyStarted(turnID: turnID)))
            beginReply(turnID)
        }
        guard var r = reply, !r.stopped else { return }
        let chunks = r.text.feed(delta)
        enqueue(chunks, into: &r)
        reply = r
    }

    private func speakEnd(_ turnID: UUID) {
        guard var r = reply, r.turnID == turnID, !r.stopped else {
            // A reply that never spoke (no text): the turn is over, listen again.
            if reply == nil, machine.state == .thinking { perform(machine.next(.replyDone)) }
            return
        }
        enqueue(r.text.finish(), into: &r)
        r.feed.finish()
        reply = r
    }

    private func enqueue(_ chunks: [SpokenChunk], into r: inout Reply) {
        let source = r.text.text
        trackerBox.withLock { $0.updateSource(source) }
        for c in chunks {
            r.lookup.m.withLock { $0[c.index] = c }
            if c.index == 0 { sign("tts.firstClauseReady", VoiceAudioSignposts.now()) }
            r.feed.yield(TTSChunk(index: c.index, text: c.text))
        }
    }

    private func beginReply(_ turnID: UUID) {
        let (stream, feed) = AsyncStream<TTSChunk>.makeStream()
        parts.sink.flush()
        let backend = parts.synthesiser(TTSPlayback(sink: parts.sink))
        trackerBox.withLock { $0 = SpokenSpanTracker() }
        var r = Reply(turnID: turnID, text: VoiceReplyText(codeOmitted: start.codeOmitted ?? SpeakableText.defaultCodeOmitted),
                      feed: feed, backend: backend)
        let box = trackerBox
        if let kokoro = backend as? KokoroBackend {
            // The chunk table: each chunk's sample count as it is synthesised (in order, contiguous in the output).
            let lookup = r.lookup
            let emit = emit
            kokoro.onSynthesizedWords = { chunk, samples, words in
                if chunk.index == 0 { emit([.voice(.signpost(name: "tts.firstChunkSynth", hostNs: VoiceAudioSignposts.now()))]) }
                let spoken = lookup.m.withLock { $0[chunk.index] } ?? SpokenChunk(index: chunk.index, text: chunk.text, source: 0..<0)
                box.withLock { $0.scheduled(spoken, samples: samples, wordStarts: words) }
            }
        }
        let events = backend.speak(stream, voice: voiceID, rate: rate)
        r.task = Task { [weak self] in
            for await e in events { await self?.ttsEvent(e, turnID: turnID) }
        }
        reply = r
    }

    private func ttsEvent(_ e: TTSEvent, turnID: UUID) {
        guard let r = reply, r.turnID == turnID, !r.stopped else { return }
        switch e {
        case .started(let i):
            barge.chunkStarted()
            if i == 0, !duplex.residualChecked, !machine.halfDuplex, !duplex.route.echoFree {
                firstChunkPlaying = true
                firstChunkBarged = false
            } else if i > 0 { endFirstChunk() }
            let text = r.lookup.m.withLock { $0[i]?.text }
            emit([.voice(.ttsStarted(chunkIndex: i))] + (text.map { [.voice(.speakingText($0))] } ?? []))
            if !r.startedAudio {
                reply?.startedAudio = true
                let firstNs = VoiceAudioSignposts.now()
                timings.firstSample.append(firstNs)
                sign("tts.firstSample", firstNs)
                perform(machine.next(.replyAudio))
            }
        case .played(let ms):
            reply?.playedMs = ms
        case .finished(let stopped):
            // The session's own stops clear `reply` first, so a stopped finish here is a synthesis failure (review
            // finding 6): the reply ends with what was heard and the session listens again.
            let played = r.playedMs
            let length = stopped ? trackerBox.withLock { $0.spokenOffset(playedSamples: parts.sink.playedSamples) } : r.text.text.utf16.count
            reply = nil
            barge.reset()
            endFirstChunk()
            gateUntilSample = inputSamples + HalfDuplexPolicy.tailMs * 16
            if stopped { AppLog.log(.voice, .error, "voice session: speech synthesis failed; reply ended") }
            emit([.voice(.ttsStopped(playedMs: played, reason: stopped ? .failed : .finished)),
                  .voice(.spokenSpan(turnID: turnID, charOffset: length))])
            perform(machine.next(.replyDone))
        }
    }

    /// Stops the reply now; with `report`, emits what was heard (`ttsStopped` + `spokenSpan`).
    private func stopReply(reason: TTSStopReason, report: Bool) {
        guard var r = reply else {
            if report { emit([.voice(.ttsStopped(playedMs: 0, reason: reason))]) }
            return
        }
        let played = parts.sink.playedSamples
        let ms = Double(played) / Double(max(1, parts.sink.sampleRate)) * 1_000
        let offset = trackerBox.withLock { $0.spokenOffset(playedSamples: played) }
        lastStopTrace = (played, trackerBox.withLock { $0.entries })
        r.stopped = true
        r.feed.finish()
        r.backend.stop()
        parts.sink.flush()
        r.task?.cancel()
        reply = nil
        barge.reset()
        if firstChunkPlaying { firstChunkBarged = firstChunkBarged || reason == .bargeIn }
        endFirstChunk()
        gateUntilSample = inputSamples + HalfDuplexPolicy.tailMs * 16
        if report {
            emit([.voice(.ttsStopped(playedMs: ms, reason: reason)), .voice(.spokenSpan(turnID: r.turnID, charOffset: offset))])
        }
    }

    /// The session's first assistant chunk stopped playing: the AEC residual check judges its frames.
    private func endFirstChunk() {
        guard firstChunkPlaying else { return }
        firstChunkPlaying = false
        if let reason = duplex.firstChunkEnded(bargedIn: firstChunkBarged) { enterHalfDuplex(reason) }
    }

    private func sign(_ name: String, _ ns: UInt64) { emit([.voice(.signpost(name: name, hostNs: ns))]) }

    // MARK: - Effects

    private func perform(_ effects: [VoiceSessionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startCapture, .stopCapture:
                break  // `begin` / `end` own the device
            case .emitState(let s):
                emit([.voice(.voiceState(s))])
            case .emitTurnEnded(let reason):
                emit([.voice(.turnEnded(reason))])
            case .emitFinal:
                break  // `finishRecogniser` emits the full `FinalTranscript`
            case .pauseOutput:
                parts.sink.pause()
            case .resumeOutput:
                parts.sink.resume()
            case .stopSpeech(_, let reason):
                stopReply(reason: reason, report: true)
            case .cancelGeneration(let turnID):
                // The app cancels the chat turn on `ttsStopped(.bargeIn)`; when nothing was speaking, say so here.
                if reply == nil, effects.contains(.stopSpeech(turnID: turnID, reason: .bargeIn)) == false {
                    emit([.voice(.ttsStopped(playedMs: 0, reason: .bargeIn))]
                         + (turnID.map { [.voice(.spokenSpan(turnID: $0, charOffset: 0))] } ?? []))
                }
            case .setOutputMuted(let on):
                parts.sink.setMuted(on)
            }
        }
    }
}
