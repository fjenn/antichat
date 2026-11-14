// M3.T09 (R-283; P-media-03): the voice conversation's end of turn. Stage 1 is the vendored speech-swift
// `StreamingVADProcessor` over live Silero (`SileroVADProvider`, Core ML), stage 2 the vendored `SmartTurn` (Core ML,
// `turn-coreml`, A-M3-01) with rechecks while the silence grows, plus Parakeet EOU on held turns and the 1.5 s cap
// (turn-loop design ported from soniqo/speech-core@ee5e023: turnCompletionThreshold, MaxSilence). Thresholds:
// `turn-thresholds.json`. M9.T05: an unfinished sentence that smart-turn calls complete ends at 1.5 s (`openEnd`);
// the early end of a finished sentence (`sentenceStable`) exists for tuning but ships off (A-M9-T05-V2).
// Signposts `voice.lastVoicedFrame`, `voice.turnEnded`, `voice.finalTranscript`
// (`EagerTurnTranscriber`: STT runs on the utterance while stage 2 decides, so the final follows the turn end at once).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import os
import SpeechSwiftVendored

/// Stage-1/stage-2 thresholds (`turn-thresholds.json`, tuned only on `turn-split-50` + `noise/`, M3.T09 step 5;
/// tuning runs in `build/at/AT-283/tuning-*.json`). Stage 2 asks smart-turn when the hold starts (`holdMs` of
/// silence, `smartTurnThreshold`) and again at each `rechecks` silence length; the 1.5 s cap always ends the turn.
public struct TurnThresholds: Codable, Equatable, Sendable {
    public struct Recheck: Codable, Equatable, Sendable {
        public var afterMs: Int
        public var threshold: Float
        public init(afterMs: Int, threshold: Float) {
            self.afterMs = afterMs
            self.threshold = threshold
        }
    }

    /// M9.T05 (tuning only; nil in the shipped file): with a finished sentence, smart-turn is asked at each of
    /// `probesMs` (silence lengths, ascending) and the turn ends at the last one when every answer is ≥ `threshold`.
    /// Measured on the live trace (`TurnEndTraceTests`, build/at/AT-283/trace-2026-11-11.json): read speech pauses
    /// 384–544 ms after finished sentences that smart-turn scores 0.96–0.99 (turn-split items 07, 28, 32, 33), so any
    /// end before ~550 ms splits them; and only 8–9 of the 20 V1 utterances are that confident early at all.
    public struct Stable: Codable, Equatable, Sendable {
        public var probesMs: [Int]
        public var threshold: Float
        public init(probesMs: [Int], threshold: Float) {
            self.probesMs = probesMs
            self.threshold = threshold
        }
    }

    public var onsetMs: Int
    public var holdMs: Int
    public var smartTurnThreshold: Float
    public var rechecks: [Recheck]
    public var maxSilenceMs: Int
    /// Near-field onset gate: while no turn is open, a frame counts as speech only when its level is ≥ this many dB
    /// above the input's noise floor (20th percentile of the last 3 s of frame levels). Background talk (`noise/cafe`
    /// at −20 dB) is speech to Silero but sits on the floor; the user, close to the mic, is well above it. Inside a turn
    /// the gate is off (soft syllables never split a turn). nil = off.
    public var levelGateDb: Float?
    /// Agreement (A-M3-T09b): stage 2 (the hold check, the rechecks, `sentenceEnd`, Parakeet EOU) ends a turn only when
    /// the transcript of the turn so far (`setTranscript`, taken at the pause) is a finished sentence. Smart-turn alone
    /// says "complete" at phrase and sentence boundaries of read speech and more often under noise; the recogniser's
    /// punctuation alone does too. A turn whose transcript is not a finished sentence ends at `maxSilenceMs`.
    public var requireSentenceEnd: Bool?
    /// With a finished sentence: after this much silence smart-turn needs only `sentenceEnd.threshold`.
    public var sentenceEnd: Recheck?
    /// With a finished sentence: the silence cap (the spec's 1.5 s); `maxSilenceMs` is then the open-sentence cap.
    public var sentenceCapMs: Int?
    /// With a finished sentence: the early end (see `Stable`). nil = off.
    public var sentenceStable: Stable?
    /// With an unfinished sentence (agreement): after `afterMs` of silence one smart-turn check; ≥ `threshold` ends the
    /// turn (the spec's 1.5 s cap, kept only where the model agrees the speaker is done — `turn-split-50` item 16, a
    /// 1.1 s pause after a comma that Silero reads as ≥ 1.5 s of silence, scores 0.01). nil = the open cap only.
    public var openEnd: Recheck?

    public init(onsetMs: Int, holdMs: Int, smartTurnThreshold: Float, rechecks: [Recheck] = [], maxSilenceMs: Int,
                levelGateDb: Float? = nil, requireSentenceEnd: Bool? = nil, sentenceEnd: Recheck? = nil,
                sentenceCapMs: Int? = nil, sentenceStable: Stable? = nil, openEnd: Recheck? = nil) {
        self.onsetMs = onsetMs
        self.holdMs = holdMs
        self.smartTurnThreshold = smartTurnThreshold
        self.rechecks = rechecks
        self.maxSilenceMs = maxSilenceMs
        self.levelGateDb = levelGateDb
        self.requireSentenceEnd = requireSentenceEnd
        self.sentenceEnd = sentenceEnd
        self.sentenceCapMs = sentenceCapMs
        self.sentenceStable = sentenceStable
        self.openEnd = openEnd
    }

    var agreement: Bool { requireSentenceEnd ?? false }

    /// The stage-2 checks in silence order: the hold, the rechecks, the finished-sentence check.
    var checks: [(check: Recheck, sentenceOnly: Bool)] {
        var c = [(Recheck(afterMs: holdMs, threshold: smartTurnThreshold), false)] + rechecks.map { ($0, false) }
        if let sentenceEnd { c.append((sentenceEnd, true)) }
        return c.sorted { $0.0.afterMs < $1.0.afterMs }
    }

    public static func load(from url: URL) throws -> TurnThresholds {
        try JSONDecoder().decode(TurnThresholds.self, from: Data(contentsOf: url))
    }

    public static func load(bundle: Bundle) throws -> TurnThresholds {
        guard let url = bundle.url(forResource: "turn-thresholds", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    public static func load() throws -> TurnThresholds { try load(bundle: .module) }

    /// The M3.md step 5 starting point, used only if the bundled data file cannot be read (logged).
    public static let specDefault = TurnThresholds(onsetMs: 250, holdMs: 200, smartTurnThreshold: 0.5, maxSilenceMs: 1500)

    public static let standard: TurnThresholds = {
        do { return try load() } catch {
            AppLog.log(.voice, .error, "turn-thresholds.json unreadable (\(error)); spec defaults")
            return specDefault
        }
    }()
}

public enum TurnDetectorEvent: Equatable, Sendable {
    case speechStarted(sample: Int)
    /// NFR-V1: an open turn has been silent for `TurnDetector.pauseMs` (once per silence stretch): the session
    /// transcribes the turn so far while stage 1 and 2 decide. `lastVoicedSample` names the speech it covers.
    case paused(lastVoicedSample: Int)
    case held(sample: Int)
    case turnEnded(
        reason: VoiceTurnEndReason,
        startSample: Int,
        endSample: Int,
        lastVoicedSample: Int,
        hostTime: UInt64,
        lastVoicedHostTime: UInt64?
    )
    case failed(String)
}

public enum VoiceAudioSignposts {
    public static let poster = OSSignposter(subsystem: AppLog.subsystem, category: "voice")

    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    public static func lastVoicedFrame(at hostTime: UInt64) {
        poster.emitEvent("voice.lastVoicedFrame")
        PerfRecorder.record("voice.lastVoicedFrame", kind: .event, durationNs: 0, endNs: hostTime)
    }

    public static func turnEnded(_ reason: VoiceTurnEndReason, at hostTime: UInt64) {
        poster.emitEvent("voice.turnEnded", "\(reason.rawValue, privacy: .public)")
        PerfRecorder.record("voice.turnEnded", kind: .event, durationNs: 0,
                            meta: ["reason": reason.rawValue], endNs: hostTime)
    }

    public static func finalTranscript(turn: TurnDetectorEvent) {
        guard case .turnEnded(_, _, _, _, let ended, let lastVoiced) = turn else { return }
        let final = now()
        poster.emitEvent("voice.finalTranscript")
        PerfRecorder.record("voice.finalTranscript", kind: .event, durationNs: 0, endNs: final)
        PerfRecorder.record("voice.turnEndedToFinal", kind: .interval,
                            durationNs: final >= ended ? final - ended : 0, endNs: final)
        if let lastVoiced {
            PerfRecorder.record("voice.lastVoicedToFinal", kind: .interval,
                                durationNs: final >= lastVoiced ? final - lastVoiced : 0, endNs: final)
        }
    }
}

private final class TurnProbabilityProvider: StreamingVADProvider, @unchecked Sendable {
    let base: any StreamingVADProvider
    let gateDb: Float?
    /// The gate applies to onsets only (no turn open): soft syllables inside a turn are never cut by it.
    var gateOnsets = true
    private(set) var lastProbability: Float = 0
    /// Frame levels (dBFS) of the last 3 s; kept across turns (the room does not change at a turn end).
    private var levels: [Float] = []
    static let floorFrames = 94  // 3 s of 32 ms frames

    init(base: any StreamingVADProvider, gateDb: Float?) {
        self.base = base
        self.gateDb = gateDb
    }
    var inputSampleRate: Int { base.inputSampleRate }
    var chunkSize: Int { base.chunkSize }

    func processChunk(_ samples: [Float]) -> Float {
        let p = base.processChunk(samples)  // always run: Silero's LSTM state follows the whole input
        lastProbability = p
        guard let gateDb else { return p }
        let level = Float(rmsDBFS(samples))
        levels.append(level)
        if levels.count > Self.floorFrames { levels.removeFirst(levels.count - Self.floorFrames) }
        let sorted = levels.sorted()
        // Under 0.5 s of history the floor is unknown: assume a quiet room (−60 dBFS) unless it is quieter still.
        let floor = sorted.count < 16 ? min(-60, sorted[0]) : max(-90, sorted[sorted.count / 5])
        if gateOnsets, level < floor + gateDb { lastProbability = 0 }
        return lastProbability
    }

    /// Model state only: the level history survives `StreamingVADProcessor.reset()` at a turn end.
    func resetState() {
        lastProbability = 0
        base.resetState()
    }

    func forgetLevels() { levels.removeAll() }
}

/// The vendored processor's stage-2 stand-in: "not complete", so only `TurnDetector.check()` asks the model.
private final class NeverComplete: TurnCompletionProvider, @unchecked Sendable {
    func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float { 0 }
}

/// M3.T09 steps 3–4 (R-283): the two-stage end of turn.
///   Stage 1 = the vendored 32 ms Silero state machine (`StreamingVADProcessor`: onset after `onsetMs` voiced,
///   hold after `holdMs` of silence). Stage 2 = smart-turn v3.2 on the turn's last 8 s (front-padded): asked when the
///   hold starts (≥ `smartTurnThreshold` ends the turn) and again at each `rechecks` silence length while the speaker
///   stays quiet; Parakeet EOU (English, T1+) ends a held turn too; **1.5 s of continuous silence always ends it**.
/// A failed smart-turn call counts as "complete" (the vendored rule: a broken model never stalls the conversation).
/// Calls are serialised by the capture worker.
public final class TurnDetector: @unchecked Sendable {
    public let thresholds: TurnThresholds
    private let provider: TurnProbabilityProvider
    private let processor: StreamingVADProcessor
    private let smartTurn: (any TurnCompletionProvider)?
    private var pending: [Float] = []
    private var processedSamples = 0
    private var turnStartSample: Int?
    private var lastVoicedSample: Int?
    private var lastVoicedHostTime: UInt64?
    /// The last 8 s of input (absolute end = `processedSamples`), for the stage-2 rechecks.
    private var recent: [Float] = []
    /// Smart-turn probabilities of the stage-2 checks asked in the current turn (hold first).
    public private(set) var stageTwoProbabilities: [Float] = []
    /// Silence after which an open turn reports `.paused` (before the hold, so the transcript is ready by then).
    public static let pauseMs = 128
    private var pausedAt: Int?
    /// `sentence` nil = the recogniser cannot transcribe at a pause (WhisperKit routing, no provisional support).
    private var transcript: (voiced: Int, sentence: Bool?)?
    private var checksDone = 0
    /// `sentenceStable` answers for the silence after `stableVoiced` (reset when the speaker goes on).
    private var stableProbes: [Float] = []
    private var stableVoiced: Int?
    /// `openEnd` was asked in this silence.
    private var openAsked = false

    public init(
        vad: any StreamingVADProvider,
        smartTurn: (any TurnCompletionProvider)? = nil,
        thresholds: TurnThresholds = .standard
    ) {
        self.thresholds = thresholds
        self.smartTurn = smartTurn
        provider = TurnProbabilityProvider(base: vad, gateDb: thresholds.levelGateDb)
        processor = StreamingVADProcessor(
            provider: provider,
            config: VADConfig(
                onset: 0.5,
                offset: 0.35,
                minSpeechDuration: Float(thresholds.onsetMs) / 1_000,
                minSilenceDuration: Float(thresholds.holdMs) / 1_000,
                windowDuration: 0.032,
                stepRatio: 1),
            // Stage 2 runs here (`check()`): the vendored hold never ends a turn by itself (no model call there),
            // only its silence cap does. Without smart-turn the hold ends the turn (the vendored rule).
            turnCompletion: smartTurn == nil ? nil : NeverComplete(),
            turnCompletionConfig: TurnCompletionConfig(
                threshold: thresholds.smartTurnThreshold,
                maxSilenceDuration: Float(thresholds.maxSilenceMs) / 1_000,
                preRollDuration: 0.5))
    }

    /// The turn's transcript so far, taken when it paused at `voicedSample` (the session's provisional transcript).
    /// Agreement (`requireSentenceEnd`) reads it only while nothing was voiced after that sample. A check that was
    /// waiting for it runs now: the returned event is the turn end it decided (nil = the turn goes on).
    /// `text` nil: no transcript can be taken at a pause for this turn (agreement falls back to smart-turn / EOU alone,
    /// capped at `sentenceCapMs`). A transcript of an older pause never replaces a newer one.
    @discardableResult
    public func setTranscript(_ text: String?, voicedSample: Int) -> TurnDetectorEvent? {
        if let t = transcript, t.voiced > voicedSample { return nil }
        transcript = (voicedSample, text.map(Self.endsSentence))
        if let end = stableCheck() { return end }
        guard processor.isHoldingTurn else { return nil }
        return check()
    }

    /// Whether the session will deliver transcripts (a recogniser runs). Without one, a turn ends as without
    /// agreement (smart-turn / EOU alone, capped at `sentenceCapMs`).
    public var expectsTranscript = true

    /// No pause transcript can exist for the speech so far: agreement does not apply to this turn.
    private var transcriptUnsupported: Bool {
        guard expectsTranscript else { return true }
        guard let t = transcript, t.voiced == lastVoicedSample else { return false }
        return t.sentence == nil
    }

    /// A finished sentence: the recogniser's text ends with sentence punctuation (Parakeet punctuates and cases).
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".?!…。？！".contains(last)
    }

    public var isHoldingTurn: Bool { processor.isHoldingTurn }
    public var isInTurn: Bool { turnStartSample != nil }
    public var lastTurnCompletionProbability: Float? { stageTwoProbabilities.last }
    /// Speech probability of the last frame (barge-in detection reads it, M3.T10).
    public var lastSpeechProbability: Float { provider.lastProbability }

    public func process(samples: [Float]) -> [TurnDetectorEvent] {
        pending.append(contentsOf: samples)
        var out: [TurnDetectorEvent] = []
        while pending.count >= provider.chunkSize {
            let frame = Array(pending.prefix(provider.chunkSize))
            pending.removeFirst(provider.chunkSize)
            out.append(contentsOf: process(frame: frame))
        }
        return out
    }

    /// Parakeet EOU's confirmed end of utterance: ends the turn only while stage 1 holds (≥ `holdMs` of silence), so
    /// an early EOU token never cuts a speaker who is still talking.
    public func endOfUtterance() -> TurnDetectorEvent? {
        guard let start = turnStartSample, processor.isHoldingTurn else { return nil }
        if thresholds.agreement, !transcriptUnsupported, sentenceKnown != true { return nil }
        let end = lastVoicedSample ?? processedSamples
        let event = ended(.eou, start: start, end: end)
        resetTurn()
        return event
    }

    /// Push-to-talk release (M3.T11): the open turn ends now, whatever stage 1 thinks.
    public func endTurnNow(reason: VoiceTurnEndReason = .ptt) -> TurnDetectorEvent? {
        guard let start = turnStartSample else { return nil }
        let event = ended(reason, start: start, end: lastVoicedSample ?? processedSamples)
        resetTurn()
        return event
    }

    public func flush() -> [TurnDetectorEvent] {
        var out: [TurnDetectorEvent] = []
        if !pending.isEmpty {
            let frame = pending + [Float](repeating: 0, count: provider.chunkSize - pending.count)
            pending.removeAll()
            out += process(frame: frame)
        }
        let wasHolding = processor.isHoldingTurn
        for event in processor.flush() {
            if case .speechEnded(let segment) = event {
                out.append(end(segment: segment, wasHolding: wasHolding))
            }
        }
        resetTurn()
        return out
    }

    public func reset() {
        pending.removeAll()
        processedSamples = 0
        recent.removeAll()
        provider.forgetLevels()
        resetTurn()
    }

    private func process(frame: [Float]) -> [TurnDetectorEvent] {
        processedSamples += frame.count
        provider.gateOnsets = turnStartSample == nil
        recent.append(contentsOf: frame)
        let window = SmartTurnModel.windowSeconds * 16_000
        if recent.count > window { recent.removeFirst(recent.count - window) }
        let wasHolding = processor.isHoldingTurn
        let events = processor.process(samples: frame)
        if provider.lastProbability >= 0.5 {
            lastVoicedSample = processedSamples
            let now = VoiceAudioSignposts.now()
            lastVoicedHostTime = now
            VoiceAudioSignposts.lastVoicedFrame(at: now)
        }
        if let silero = provider.base as? SileroVADProvider, let error = silero.lastError {
            return [.failed("\(error)")]
        }
        var out: [TurnDetectorEvent] = []
        for event in events {
            switch event {
            case .speechStarted(let time):
                let start = absoluteSample(relativeTime: time)
                turnStartSample = start
                out.append(.speechStarted(sample: start))
            case .speechEnded(let segment):
                out.append(end(segment: segment, wasHolding: wasHolding))
                resetTurn()
                return out
            }
        }
        if !wasHolding, processor.isHoldingTurn {
            checksDone = 0
            out.append(.held(sample: lastVoicedSample ?? processedSamples))
        }
        if turnStartSample != nil, let voiced = lastVoicedSample, pausedAt != voiced,
           (processedSamples - voiced) / 16 >= Self.pauseMs {
            pausedAt = voiced
            out.append(.paused(lastVoicedSample: voiced))
        }
        if turnStartSample != nil, let end = stableCheck() {
            out.append(end)
            return out
        }
        if processor.isHoldingTurn, let end = check() { out.append(end) }
        if !processor.isHoldingTurn {
            checksDone = 0
            openAsked = false
        }
        return out
    }

    /// Whether the transcript of the speech so far is a finished sentence; nil while it is still being taken.
    private var sentenceKnown: Bool? {
        guard let t = transcript, t.voiced == lastVoicedSample else { return nil }
        return t.sentence
    }

    /// Stage 2 at each check's silence length (`TurnThresholds.checks`), then the finished-sentence cap. With
    /// agreement a due check waits for the transcript (taken from the pause on, ≈ 50 ms) and counts only on a
    /// finished sentence.
    private func check() -> TurnDetectorEvent? {
        guard let start = turnStartSample else { return nil }
        let silenceMs = (processedSamples - (lastVoicedSample ?? processedSamples)) / 16
        let checks = thresholds.checks
        let unsupported = thresholds.agreement && transcriptUnsupported
        let agreement = thresholds.agreement && !unsupported
        let sentence = sentenceKnown
        // A finished sentence ends at the sentence cap; a turn without a pause transcript at the spec's 1.5 s.
        if let sentenceCap = thresholds.sentenceCapMs, agreement && sentence == true || unsupported,
           silenceMs >= (unsupported ? max(sentenceCap, 1_500) : sentenceCap) {
            let event = ended(.silenceCap, start: start, end: lastVoicedSample ?? processedSamples)
            resetTurn()
            return event
        }
        // An unfinished sentence: one smart-turn check at `openEnd` (before the open cap).
        if let open = thresholds.openEnd, agreement, sentence == false, !openAsked, silenceMs >= open.afterMs,
           let smartTurn {
            openAsked = true
            if ask(smartTurn, start: start) >= open.threshold {
                let event = ended(.smartTurn, start: start, end: lastVoicedSample ?? processedSamples)
                resetTurn()
                return event
            }
        }
        guard checksDone < checks.count, let smartTurn else { return nil }
        let (c, sentenceOnly) = checks[checksDone]
        guard silenceMs >= c.afterMs else { return nil }
        if unsupported, sentenceOnly {  // a check that needs a finished sentence cannot count without a transcript
            checksDone += 1
            return nil
        }
        if agreement || (sentenceOnly && !unsupported) {
            guard let sentence else { return nil }  // the transcript is on its way
            if !sentence {
                checksDone += 1
                return nil
            }
        }
        checksDone += 1
        guard ask(smartTurn, start: start) >= c.threshold else { return nil }
        let event = ended(.smartTurn, start: start, end: lastVoicedSample ?? processedSamples)
        resetTurn()
        return event
    }

    /// `sentenceStable` (M9.T05): smart-turn at each probe's silence length (asked whether or not the transcript is in
    /// yet, so the answers belong to those silence lengths); the turn ends once every probe is ≥ the threshold and the
    /// transcript of the speech so far is a finished sentence (an answer arriving later ends it then).
    private func stableCheck() -> TurnDetectorEvent? {
        guard let rule = thresholds.sentenceStable, !rule.probesMs.isEmpty, thresholds.agreement, !transcriptUnsupported,
              let smartTurn, let start = turnStartSample, let voiced = lastVoicedSample else { return nil }
        if stableVoiced != voiced {
            stableVoiced = voiced
            stableProbes.removeAll()
        }
        guard stableProbes.allSatisfy({ $0 >= rule.threshold }) else { return nil }
        let silenceMs = (processedSamples - voiced) / 16
        if stableProbes.count < rule.probesMs.count, silenceMs >= rule.probesMs[stableProbes.count] {
            stableProbes.append(ask(smartTurn, start: start))
        }
        guard stableProbes.count == rule.probesMs.count, stableProbes.allSatisfy({ $0 >= rule.threshold }),
              sentenceKnown == true else { return nil }
        let event = ended(.smartTurn, start: start, end: voiced)
        resetTurn()
        return event
    }

    /// Smart-turn on the turn's audio (its last 8 s, from the onset); a failed call counts as "complete" (the vendored
    /// rule: a broken model never stalls the conversation).
    private func ask(_ smartTurn: any TurnCompletionProvider, start: Int) -> Float {
        let first = processedSamples - recent.count
        let from = max(0, max(start, first) - first)
        let p: Float
        do { p = try smartTurn.turnCompleteProbability(audio: Array(recent[from...]), sampleRate: 16_000) } catch { p = 1 }
        stageTwoProbabilities.append(p)
        return p
    }

    private func end(segment: SpeechSegment, wasHolding: Bool) -> TurnDetectorEvent {
        let start = turnStartSample ?? absoluteSample(relativeTime: segment.startTime)
        let end = absoluteSample(relativeTime: segment.endTime)
        return ended(wasHolding ? .silenceCap : .smartTurn, start: start, end: end)
    }

    private func ended(
        _ reason: VoiceTurnEndReason,
        start: Int,
        end: Int
    ) -> TurnDetectorEvent {
        let time = VoiceAudioSignposts.now()
        VoiceAudioSignposts.turnEnded(reason, at: time)
        return .turnEnded(
            reason: reason,
            startSample: start,
            endSample: end,
            lastVoicedSample: lastVoicedSample ?? end,
            hostTime: time,
            lastVoicedHostTime: lastVoicedHostTime)
    }

    private func absoluteSample(relativeTime: Float) -> Int {
        max(0, processedSamples - Int((processor.currentTime - relativeTime) * 16_000))
    }

    private func resetTurn() {
        processor.reset()
        turnStartSample = nil
        lastVoicedSample = nil
        lastVoicedHostTime = nil
        checksDone = 0
        pausedAt = nil
        transcript = nil
        stableProbes.removeAll()
        stableVoiced = nil
        openAsked = false
        stageTwoProbabilities.removeAll()
    }
}

/// Keeps the selected recogniser running while stage 2 decides, then finishes the already-buffered utterance.
public actor EagerTurnTranscriber {
    private let backend: any SpeechBackend
    private var reader: Task<Void, Never>?
    public private(set) var latestPartial = ""

    public init(backend: any SpeechBackend) { self.backend = backend }

    public func start(locale: Locale?, onEOU: @escaping @Sendable () -> Void,
                      onPartial: (@Sendable (String) -> Void)? = nil) async throws {
        let stream = try await backend.start(locale: locale)
        reader = Task { [weak self] in
            for await event in stream {
                switch event {
                case .partial(let text):
                    onPartial?(text)
                    await self?.receive(text)
                case .endOfUtterance: onEOU()
                }
            }
        }
    }

    nonisolated public func append(samples: [Float]) { backend.append(samples: samples) }

    /// The transcript so far (the recogniser stays open); nil when the backend cannot say.
    public func provisional() async -> FinalTranscript? { try? await backend.provisional() }

    public func finish(turn: TurnDetectorEvent) async throws -> FinalTranscript {
        let final = try await backend.finish()
        reader?.cancel()
        await reader?.value
        reader = nil
        VoiceAudioSignposts.finalTranscript(turn: turn)
        return final
    }

    public func cancel() async {
        await backend.cancel()
        reader?.cancel()
        await reader?.value
        reader = nil
    }

    private func receive(_ text: String) { latestPartial = text }
}
