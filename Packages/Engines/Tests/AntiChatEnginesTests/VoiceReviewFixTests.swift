// M3 close review (docs/prd/reviews/M3-review.md): the helper-side fixes, each through the real session / service
// code with injected devices (pushed frames, a modelled playback device, fake recognisers). Real models: none.
//   make test-unit FILTER=VoiceReviewFixTests
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import SpeechSwiftVendored
import Synchronization
import Testing
@testable import AntiChatEngines

// MARK: - Test doubles

/// Opens once; every waiter (before or after) continues.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class Counter: Sendable {
    private let m = Mutex(0)
    func inc() { m.withLock { $0 += 1 } }
    var value: Int { m.withLock { $0 } }
}

/// PushCapture that counts starts and stops.
final class CountingCapture: AudioCaptureSource, @unchecked Sendable {
    let inner = PushCapture()
    let starts = Counter(), stops = Counter()
    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        starts.inc()
        try inner.start(onSamples)
    }
    func stop() {
        stops.inc()
        inner.stop()
    }
    func push(_ s: [Float]) { inner.push(s) }
}

/// A recogniser whose start fails (the language needs a model that is not there).
final class FailingStartBackend: SpeechBackend, @unchecked Sendable {
    let engine: STTEngineID = .parakeet
    let supportsPartials = false
    let languages: Set<String> = ["en"]
    let cancels = Counter()
    func start(locale: Locale?) async throws -> AsyncStream<STTEvent> {
        throw AntiChatError.voice("unavailable", "stt-multi (other languages) is not installed")
    }
    func append(samples: [Float]) {}
    func finish() async throws -> FinalTranscript { FinalTranscript(text: "", language: "en", engine: .parakeet) }
    func cancel() async { cancels.inc() }
    func provisional() async throws -> FinalTranscript? { nil }
}

/// Chunk audio by text: "Done." is 0.5 s and arrives `stall` late (the tool call between the sentences); any other
/// chunk is `seconds` long. With `until`, "Done." is held instead until that condition holds (bounded by 15 s): a
/// stall defined by what the device did, not by the wall clock (a 1.5 s sleep raced 1 s of modelled playback under load).
struct StallingSynth: SpeechSynthesizing {
    let name = "stalling"
    var seconds = 1.0
    var stall: Duration = .milliseconds(1_500)
    var until: (@Sendable () -> Bool)?
    func synthesize(_ text: String) async throws -> SynthesizedAudio {
        if text.hasPrefix("Done") {
            if let until {
                await Wait.until("the stalled chunk's release condition") { until() }
            } else {
                try await Task.sleep(for: stall)
            }
            return SynthesizedAudio(samples: [Float](repeating: 0.001, count: 12_000), sampleRate: 24_000)
        }
        return SynthesizedAudio(samples: [Float](repeating: 0.001, count: Int(seconds * 24_000)), sampleRate: 24_000)
    }
}

/// A model of the session's VPIO output (`FullDuplexAudioIO` as patched, UP-SS-007/009): buffers play in real time;
/// a burst starts once 3 buffers are queued (8 after the queue ran dry: the recovery prebuffer) or at
/// `playPrebuffered`; a dry queue ends the burst (a stall); `routeChange` drops everything queued without a callback
/// and reports the reset (the graph rebuilt after a device change); `volume` is the player volume.
final class ModelPlaybackDevice: VoicePlaybackDevice, @unchecked Sendable {
    private struct Buffer { var count: Int; var onPlayed: (@Sendable () -> Void)? }
    private struct S {
        var started = false
        var paused = false
        var target = 3
        var prebuffer: [Buffer] = []
        var queue: [Buffer] = []
        var generation = 0
        var volume: Float = 1
        var drains = 0
        var played = 0
        var mutedPlayed = 0
        var dropping = false
        var onReset: (@Sendable () -> Void)?
    }
    private let s = Mutex(S())
    private var player: Task<Void, Never>?

    init() {
        player = Task { [weak self] in await self?.run() }
    }

    deinit { player?.cancel() }

    var volume: Float { s.withLock { $0.volume } }
    var drains: Int { s.withLock { $0.drains } }
    /// Samples played out so far.
    var played: Int { s.withLock { $0.played } }
    /// Nothing queued or prebuffered and no burst running.
    var idle: Bool { s.withLock { !$0.started && $0.queue.isEmpty && $0.prebuffer.isEmpty } }
    /// Samples that played while the volume was 0.
    var mutedPlayed: Int { s.withLock { $0.mutedPlayed } }
    var dropping: Bool {
        get { s.withLock { $0.dropping } }
        set { s.withLock { $0.dropping = newValue } }
    }

    var onPlaybackReset: (@Sendable () -> Void)? {
        get { s.withLock { $0.onReset } }
        set { s.withLock { $0.onReset = newValue } }
    }

    func schedulePlayback(_ samples: [Float], onPlayed: (@Sendable () -> Void)?) -> Bool {
        s.withLock { st in
            guard !st.dropping else { return false }
            let b = Buffer(count: samples.count, onPlayed: onPlayed)
            if st.started {
                st.queue.append(b)
            } else {
                st.prebuffer.append(b)
                if st.prebuffer.count >= st.target { Self.startBurst(&st) }
            }
            return true
        }
    }

    private static func startBurst(_ st: inout S) {
        st.queue += st.prebuffer
        st.prebuffer = []
        st.started = true
    }

    func pausePlayback() { s.withLock { $0.paused = true } }
    func resumePlayback() { s.withLock { $0.paused = false } }
    func flushPlayback() {
        s.withLock { st in
            st.queue = []; st.prebuffer = []; st.started = false; st.paused = false; st.target = 3; st.generation += 1
        }
    }
    func setPlaybackVolume(_ volume: Float) { s.withLock { $0.volume = volume } }
    func playPrebuffered() {
        s.withLock { st in if !st.started, !st.prebuffer.isEmpty { Self.startBurst(&st) } }
    }

    func routeChange() {
        let reset = s.withLock { st -> (@Sendable () -> Void)? in
            st.queue = []; st.prebuffer = []; st.started = false; st.target = 3; st.generation += 1
            return st.onReset
        }
        reset?()
    }

    private func run() async {
        while !Task.isCancelled {
            let head = s.withLock { st -> (Buffer, Int)? in
                guard st.started, !st.paused, let h = st.queue.first else { return nil }
                return (h, st.generation)
            }
            guard let (buffer, generation) = head else {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            try? await Task.sleep(for: .microseconds(buffer.count * 1_000_000 / 24_000))
            let fire = s.withLock { st -> Bool in
                guard st.generation == generation, !st.queue.isEmpty else { return false }
                st.queue.removeFirst()
                st.played += buffer.count
                if st.volume == 0 { st.mutedPlayed += buffer.count }
                if st.queue.isEmpty {  // ran dry: the burst ends, the next one waits for the recovery prebuffer
                    st.started = false
                    st.target = 8
                    st.drains += 1
                }
                return true
            }
            if fire { buffer.onPlayed?() }
        }
    }
}

enum Wait {
    /// A bounded wait on a real condition.
    static func until(_ what: String, timeout: Double = 15, _ cond: () async -> Bool) async {
        let end = ContinuousClock.now + .seconds(timeout)
        while await !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await cond(), "timed out waiting for \(what)")
    }
}

extension VoiceSink {
    var errorCode: String? {
        for i in items { if case .engine(.error(let e)) = i { return e.fullCode } }
        return nil
    }
    var bargeIns: Int { voice.filter { if case .ttsStopped(_, .bargeIn) = $0 { true } else { false } }.count }
    var finishedReplies: Int { voice.filter { if case .ttsStopped(_, .finished) = $0 { true } else { false } }.count }
    var listeningCount: Int { voice.filter { $0 == .voiceState(.listening) }.count }
}

// MARK: - P0-1, P1-1, P0-2, P2-3: the session service

@Suite(.serialized) struct VoiceSessionServiceReviewTests {
    static func parts(capture: CountingCapture, released: Counter? = nil, recogniser: (@Sendable () async throws -> (backend: any SpeechBackend, leases: [VoiceModelLease]))? = nil,
                      texts: [String] = ["Hello there."]) -> VoiceSessionParts {
        let queue = Mutex(texts)
        return VoiceSessionParts(
            capture: capture, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: recogniser ?? {
                let t = queue.withLock { $0.isEmpty ? "Again." : $0.removeFirst() }
                return (FakeBackend(finalText: t), [])
            },
            synthesiser: { KokoroBackend(tts: SilentSynth(), playback: $0) },
            sink: ClockedSilentSink(),
            leases: released.map { r in [VoiceModelLease(object: 0) { r.inc() }] } ?? [])
    }

    /// P0-1: End while the models lease: capture never starts, the leases go back, the stream ends `done`.
    @Test func endWhileConnectingNeverStartsCapture() async {
        let gate = Gate(), released = Counter(), capture = CountingCapture()
        let svc = VoiceSessionService { _, _ in
            await gate.wait()
            return Self.parts(capture: capture, released: released)
        }
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        svc.prepare(start.requestID)
        let sink = VoiceSink()
        let run = Task { await svc.start(start, models: VoiceModelSet(slots: [:]), emit: sink.emit) }
        await svc.end(VoiceSessionEnd(requestID: start.requestID))  // before the models are there
        await gate.release()
        await run.value
        #expect(sink.terminal == .done(.stop))
        #expect(capture.starts.value == 0, "the microphone was never opened")
        #expect(released.value == 1, "the session's leases went back")
        #expect(!svc.exists(start.requestID))
    }

    /// AT-FA-05: End of a running session — the stream's terminal is out before `start` (the request's body) returns.
    /// The router closes a request whose body returned without one as `engine.noTerminal`; in the clean VM the body
    /// returned (session ended) before `finish` had sent `done`, and the last spoken turn ended in that error.
    @Test func endOfARunningSessionSendsItsTerminalBeforeTheRequestReturns() async {
        for _ in 0..<20 {
            let capture = CountingCapture()
            let svc = VoiceSessionService { _, _ in Self.parts(capture: capture) }
            let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
            svc.prepare(start.requestID)
            let order = Mutex<[String]>([])
            let sink = VoiceSink()
            let run = Task {
                await svc.start(start, models: VoiceModelSet(slots: [:]), emit: { items in
                    if items.contains(where: \.isTerminal) { order.withLock { $0.append("terminal") } }
                    sink.emit(items)
                })
                order.withLock { $0.append("returned") }
            }
            await Wait.until("running") { svc.session(start.requestID) != nil }
            await svc.end(VoiceSessionEnd(requestID: start.requestID))
            await run.value
            #expect(order.withLock { $0 } == ["terminal", "returned"])
            #expect(sink.terminal == .done(.stop))
            #expect(sink.items.filter(\.isTerminal).count == 1)
        }
    }

    /// P0-1: the request cancelled (the app's cancel) while the models lease: same, no capture.
    @Test func cancelWhileConnectingNeverStartsCapture() async {
        let gate = Gate(), released = Counter(), capture = CountingCapture()
        let svc = VoiceSessionService { _, _ in
            await gate.wait()
            return Self.parts(capture: capture, released: released)
        }
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        let sink = VoiceSink()
        let run = Task { await svc.start(start, models: VoiceModelSet(slots: [:]), emit: sink.emit) }
        await Wait.until("building") { svc.exists(start.requestID) }
        run.cancel()
        await gate.release()
        await run.value
        #expect(capture.starts.value == 0)
        #expect(released.value == 1)
        #expect(sink.terminal == .done(.cancelled))
    }

    /// P1-1: mic mute pressed while connecting holds from the first frame: nothing is heard or answered.
    @Test func muteWhileConnectingAppliesBeforeAnythingIsHeard() async {
        let gate = Gate(), capture = CountingCapture()
        let svc = VoiceSessionService { _, _ in
            await gate.wait()
            return Self.parts(capture: capture)
        }
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        svc.prepare(start.requestID)
        let sink = VoiceSink()
        let run = Task { await svc.start(start, models: VoiceModelSet(slots: [:]), emit: sink.emit) }
        await svc.control(VoiceSessionControl(requestID: start.requestID, action: .muteMic))
        await gate.release()
        await Wait.until("running") { svc.session(start.requestID) != nil }
        capture.push(PushCapture.loud(0.6) + PushCapture.quiet(0.6))
        await Wait.until("levels") { sink.levels.count >= 30 }
        #expect(sink.levels.allSatisfy { $0 == -120 }, "the meter shows a muted mic")
        #expect(sink.finals.isEmpty)
        #expect(!sink.voice.contains(.voiceState(.transcribing)))
        await svc.end(VoiceSessionEnd(requestID: start.requestID))
        await run.value
    }

    /// P0-2: the recogniser fails on the first utterance: the session ends (capture off, every lease back), then the
    /// error is the stream's one terminal.
    @Test func recogniserFailureEndsTheSessionProperly() async {
        let capture = CountingCapture(), released = Counter(), recogniserReleased = Counter()
        let backend = FailingStartBackend()
        let svc = VoiceSessionService { _, _ in
            Self.parts(capture: capture, released: released, recogniser: {
                (backend, [VoiceModelLease(object: 0) { recogniserReleased.inc() }])
            })
        }
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        let sink = VoiceSink()
        let run = Task { await svc.start(start, models: VoiceModelSet(slots: [:]), emit: sink.emit) }
        await Wait.until("running") { svc.session(start.requestID) != nil }
        capture.push(PushCapture.loud(0.5) + PushCapture.quiet(0.3))
        await sink.waitTerminal()
        await run.value
        #expect(sink.errorCode == "voice.unavailable")
        #expect(sink.items.filter(\.isTerminal).count == 1)
        #expect(capture.stops.value >= 1, "capture stopped")
        #expect(released.value == 1, "session leases released")
        #expect(recogniserReleased.value == 1, "the failed recogniser's leases released")
        #expect(backend.cancels.value == 1)
        #expect(!svc.exists(start.requestID))
        #expect(sink.voice.contains(.voiceState(.idle)))
    }

    /// P0-2: a spoken language outside Parakeet's without `stt-multi` fails at the start, before any lease.
    @Test func otherLanguageWithoutSttMultiFailsFast() async {
        struct CountingProvider: VoiceModelProvider {
            let leases: Counter
            func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
                leases.inc()
                return VoiceModelLease(object: 0) {}
            }
        }
        let slot = ModelSlot(engine: .coreml, key: "x", path: "/x")
        let models = VoiceModelSet(slots: [.stt: slot, .vad: slot, .turn: slot, .tts: slot])
        let leases = Counter()
        let start = VoiceSessionStart(chatID: UUID(), locale: "ja", voiceID: "af_heart")
        await #expect(throws: AntiChatError.self) {
            _ = try await VoiceSessionService.standardParts(start, models, provider: CountingProvider(leases: leases), live: PushCapture())
        }
        #expect(leases.value == 0)
    }

    /// P2-3: the capture graph is lost for good (rebuild failed twice): the session ends with `voice.noDevice`.
    @Test func lostCaptureGraphEndsWithNoDevice() async {
        let capture = CountingCapture(), released = Counter()
        let handler = Mutex<(@Sendable (Error) -> Void)?>(nil)
        let svc = VoiceSessionService { _, _ in
            var p = Self.parts(capture: capture, released: released)
            p.watchDevice = { h in handler.withLock { $0 = h } }
            return p
        }
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        let sink = VoiceSink()
        let run = Task { await svc.start(start, models: VoiceModelSet(slots: [:]), emit: sink.emit) }
        await Wait.until("watching") { handler.withLock { $0 } != nil }
        handler.withLock { $0 }?(CocoaError(.featureUnsupported))
        await sink.waitTerminal()
        await run.value
        #expect(sink.errorCode == "voice.noDevice")
        #expect(capture.stops.value >= 1)
        #expect(released.value == 1)
    }

    /// P2-1 (service side): an End routed before the start reached the service is kept.
    @Test func endBeforeStartIsKept() async {
        let capture = CountingCapture()
        let svc = VoiceSessionService { _, _ in Self.parts(capture: capture) }
        let service = VoiceService(sessions: svc)
        let start = VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")
        let sink = VoiceSink()
        service.prepare(.sessionStart(start))  // the router registers it in arrival order …
        await service.handle(.sessionEnd(VoiceSessionEnd(requestID: start.requestID)), emit: { _ in })  // … the End overtakes the Task
        await service.handle(.sessionStart(start), emit: sink.emit)
        #expect(sink.terminal == .done(.stop))
        #expect(capture.starts.value == 0)
        #expect(service.activeStreams == 0)
    }
}

// MARK: - P1-2: read aloud stopped while Kokoro loads

@Suite struct ReadAloudStopReviewTests {
    struct GatedProvider: VoiceModelProvider {
        let gate: Gate
        let released: Counter
        func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
            await gate.wait()
            return VoiceModelLease(object: SilentSynth() as any SpeechSynthesizing) { released.inc() }
        }
    }

    @Test func stopDuringTheModelLoadIsKept() async {
        let gate = Gate(), released = Counter(), spoke = Counter()
        let svc = TTSService(basic: nil, provider: GatedProvider(gate: gate, released: released)) { synth in
            spoke.inc()
            return KokoroBackend(tts: synth, output: .silent)
        }
        let models = VoiceModelSet(slots: [.tts: ModelSlot(engine: .coreml, key: "tts", path: "/x")])
        let request = Speak(text: "A long answer that should never be heard.", voiceID: "")
        let service = VoiceService(tts: svc)
        let sink = VoiceSink()
        await service.handle(.models(models), emit: { _ in })
        service.prepare(.speak(request))
        let run = Task { await service.handle(.speak(request), emit: sink.emit) }
        await service.handle(.speakStop(SpeakStop(requestID: request.requestID)), emit: { _ in })
        await gate.release()
        await run.value
        #expect(sink.voice.contains(.ttsStopped(playedMs: 0, reason: .stopped)), "\(sink.items)")
        #expect(!sink.voice.contains { if case .ttsStarted = $0 { true } else { false } }, "nothing played")
        #expect(sink.terminal == .done(.stop))
        #expect(released.value == 1)
        _ = spoke.value
    }
}

// MARK: - P1-3, P1-4: the duplex output

@Suite(.serialized) struct DuplexOutputReviewTests {
    static func speak(_ backend: KokoroBackend, _ texts: [String]) -> AsyncStream<TTSEvent> {
        let (stream, feed) = AsyncStream<TTSChunk>.makeStream()
        for (i, t) in texts.enumerated() { feed.yield(TTSChunk(index: i, text: t)) }
        feed.finish()
        return backend.speak(stream, voice: "", rate: 1)
    }

    /// The played time the backend reported last (it flushes the sink after `finished`).
    static func lastPlayedMs(_ events: [TTSEvent]) -> Double? {
        events.compactMap { if case .played(let ms) = $0 { ms } else { nil } }.last
    }

    static func collect(_ events: AsyncStream<TTSEvent>, timeout: Double = 12) async -> [TTSEvent] {
        let box = Mutex<[TTSEvent]>([])
        let task = Task { for await e in events { box.withLock { $0.append(e) } } }
        await Wait.until("finished", timeout: timeout) {
            box.withLock { $0.contains { if case .finished = $0 { true } else { false } } }
        }
        task.cancel()
        return box.withLock { $0 }
    }

    /// P1-4: the next chunk arrives after the previous one played out (a tool call): the reply still finishes, its
    /// short last chunk plays (it is under the 800 ms recovery prebuffer), and every chunk is announced.
    @Test func stallMidReplyStillFinishes() async {
        let device = ModelPlaybackDevice()
        let sink = DuplexOutputSink(audio: device)
        // "Done." is released only once the first chunk (1 s = 24 000 samples) has played out and the device sits
        // idle: the stall happens by construction, however slowly a loaded host runs the modelled playback.
        let synth = StallingSynth(until: { device.played >= 24_000 && device.idle })
        let backend = KokoroBackend(tts: synth, playback: TTSPlayback(sink: sink))
        let events = await Self.collect(Self.speak(backend, ["Let me look that up.", "Done."]), timeout: 30)
        #expect(events.contains(.finished(stopped: false)))
        #expect(events.contains(.started(chunk: 1)))
        #expect(device.drains >= 2, "the queue ran dry between the chunks (the stall) and at the end")
        #expect(Self.lastPlayedMs(events) == 1_500, "the played clock counts both bursts (1 s + 0.5 s)")
    }

    /// P1-4: the graph is rebuilt mid-reply (headphones plugged in): the queued audio is gone; the reply finishes.
    @Test func routeChangeMidReplyStillFinishes() async {
        let device = ModelPlaybackDevice()
        let sink = DuplexOutputSink(audio: device)
        let backend = KokoroBackend(tts: StallingSynth(seconds: 2), playback: TTSPlayback(sink: sink))
        let box = Mutex<[TTSEvent]>([])
        let task = Task { for await e in Self.speak(backend, ["A two second sentence that plays."]) { box.withLock { $0.append(e) } } }
        await Wait.until("playing") { sink.playedSamples >= 4_800 }
        device.routeChange()
        await Wait.until("finished", timeout: 8) { box.withLock { $0.contains { if case .finished = $0 { true } else { false } } } }
        task.cancel()
        let events = box.withLock { $0 }
        #expect(events.contains(.finished(stopped: false)))
        #expect((Self.lastPlayedMs(events) ?? 2_000) < 2_000, "the lost audio is not counted as heard")
    }

    /// P1-4: audio handed over while the graph is rebuilding never plays and is not owed.
    @Test func audioDroppedDuringARebuildIsNotOwed() async {
        let device = ModelPlaybackDevice()
        let sink = DuplexOutputSink(audio: device)
        try? sink.prepare(sampleRate: 24_000)
        device.dropping = true
        sink.schedule([Float](repeating: 0, count: 4_800))
        #expect(sink.scheduledSamples == 0)
        #expect(!sink.hasPendingAudio)
    }

    /// P1-3: speaker mute silences what is already queued (the player volume) and unmute brings it back; the clock runs.
    @Test func speakerMuteAppliesToQueuedAudio() async {
        let device = ModelPlaybackDevice()
        let sink = DuplexOutputSink(audio: device)
        try? sink.prepare(sampleRate: 24_000)
        sink.schedule([Float](repeating: 0.1, count: 48_000))  // 2 s queued at once
        await Wait.until("playing") { sink.playedSamples > 0 }
        sink.setMuted(true)
        #expect(device.volume == 0)
        await Wait.until("muted audio played") { device.mutedPlayed > 0 }
        sink.setMuted(false)
        #expect(device.volume == 1)
        await Wait.until("all played") { !sink.hasPendingAudio }
        #expect(sink.playedSamples == 48_000, "muted audio still counts as played (the spoken span)")
    }

    /// P1-4 end to end: a reply with a stall goes back to listening (half duplex: the mic opens again).
    @Test func sessionReturnsToListeningAfterAStalledReply() async throws {
        let device = ModelPlaybackDevice()
        let sink = VoiceSink()
        let mic = PushCapture()
        let parts = VoiceSessionParts(
            capture: mic, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: { (FakeBackend(finalText: "What is the weather?"), []) },
            synthesiser: { KokoroBackend(tts: StallingSynth(), playback: $0) },
            sink: DuplexOutputSink(audio: device), route: .noEchoCancellation)
        let s = VoiceSession(start: VoiceSessionStart(chatID: UUID(), voiceID: "af_heart"), parts: parts, emit: sink.emit)
        try await s.begin()
        #expect(await s.isHalfDuplex)
        mic.push(PushCapture.loud(0.5) + PushCapture.quiet(0.5))
        await Wait.until("final") { sink.finals.count == 1 }
        let turn = UUID()
        await s.control(.speak(text: "Let me look that up. ", turnID: turn))
        await Wait.until("speaking") { await s.state == .speaking }
        await s.control(.speak(text: "Done.", turnID: turn))
        await s.control(.speakEnd(turnID: turn))
        await Wait.until("listening again") { await s.state == .listening }
        #expect(sink.finishedReplies == 1)
        await s.end()
    }
}

// MARK: - P1-5: a spoken approval answered through the session

@Suite(.serialized) struct SpokenApprovalSessionTests {
    /// The control sequence `VoiceTurnBridge` sends for a reply that hits an ApprovalCard: the text so far, the prompt,
    /// `speakEnd` (the spoken segment ends at the question); after the answer the reply goes on as a new segment.
    func run(route: VoiceAudioRoute) async throws {
        let sink = VoiceSink()
        let mic = PushCapture()
        let texts = Mutex(["Write a note that says hello.", "Allow once."])
        let parts = VoiceSessionParts(
            capture: mic, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: { (FakeBackend(finalText: texts.withLock { $0.isEmpty ? "Again." : $0.removeFirst() }), []) },
            synthesiser: { KokoroBackend(tts: SilentSynth(), playback: $0) },
            sink: ClockedSilentSink(), route: route)
        let s = VoiceSession(start: VoiceSessionStart(chatID: UUID(), voiceID: "af_heart"), parts: parts, emit: sink.emit)
        try await s.begin()
        mic.push(PushCapture.loud(0.5) + PushCapture.quiet(0.5))
        await Wait.until("question") { sink.finals.count == 1 }
        let segment1 = UUID()
        await s.control(.speak(text: "Sure.", turnID: segment1))
        await s.control(.speak(text: "\n\nWrite note. Allow?\n\n", turnID: segment1))
        await s.control(.speakEnd(turnID: segment1))
        await Wait.until("prompt played, listening") { sink.finishedReplies == 1 }
        #expect(await s.state == .listening)
        // The answer, after the prompt (half duplex: past the 300 ms tail): a normal turn, not a barge-in.
        mic.push(PushCapture.quiet(0.4) + PushCapture.loud(0.5) + PushCapture.quiet(0.5))
        await Wait.until("answer") { sink.finals.count == 2 }
        #expect(sink.finals.last?.text == "Allow once.")
        #expect(sink.bargeIns == 0)
        // The reply goes on after the approval.
        let segment2 = UUID()
        await s.control(.speak(text: "Done, the note is saved.", turnID: segment2))
        await s.control(.speakEnd(turnID: segment2))
        await Wait.until("second segment finished") { sink.finishedReplies == 2 }
        #expect(sink.voice.contains(.spokenSpan(turnID: segment2, charOffset: 24)))
        await s.end()
    }

    @Test func fullDuplex() async throws { try await run(route: .injected) }
    @Test func halfDuplex() async throws { try await run(route: .noEchoCancellation) }
}

// MARK: - P1-6, P2-2, P2-1: dictation

@Suite struct DictationReviewTests {
    /// P1-6: nobody stops the dictation: it stops by itself at the maximum length (as ■) and gives its leases back.
    @Test func dictationStopsAtTheMaximumLength() async throws {
        let backend = FakeBackend()
        let released = Counter()
        let svc = STTService(
            provider: FakeProvider(),
            capture: { start in try ScriptedVoice(script: URL(fileURLWithPath: start.scriptedInput!), speed: 4) },
            vad: { _ in EnergyVAD() },
            backend: { _, _, _ in (backend, [VoiceModelLease(object: 0) { released.inc() }]) },
            maxDictation: .seconds(1))
        let sink = VoiceSink()
        let start = DictationStart(scriptedInput: try DictationServiceTests.script(30).path)
        await svc.startDictation(start, models: DictationServiceTests.models, emit: sink.emit)
        #expect(sink.terminal == .done(.stop))
        #expect(sink.finals.count == 1)
        #expect(released.value == 1)
    }

    /// P2-2: the capture fails to start after the recogniser started: the recogniser is closed.
    @Test func captureStartFailureClosesTheRecogniser() async {
        final class BrokenCapture: AudioCaptureSource, @unchecked Sendable {
            func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws { throw CocoaError(.featureUnsupported) }
            func stop() {}
        }
        let backend = FakeBackend()
        let svc = STTService(provider: FakeProvider(), capture: { _ in BrokenCapture() }, vad: { _ in nil },
                             backend: { _, _, _ in (backend, []) })
        let sink = VoiceSink()
        await svc.startDictation(DictationStart(), models: DictationServiceTests.models, emit: sink.emit)
        #expect(sink.errorCode != nil)
        #expect(backend.calls.withLock { $0 } == ["start", "cancel"])
    }

    /// P2-1: a × routed before the start reached the service ends the dictation without opening anything.
    @Test func cancelBeforeStartIsKept() async throws {
        let backend = FakeBackend()
        let svc = DictationServiceTests.service(backend)
        let service = VoiceService(stt: svc)
        let start = DictationStart(scriptedInput: try DictationServiceTests.script(30).path)
        let sink = VoiceSink()
        service.prepare(.dictationStart(start))
        await service.handle(.dictationStop(DictationStop(requestID: start.requestID, mode: .cancel)), emit: { _ in })
        await service.handle(.dictationStart(start), emit: sink.emit)
        #expect(sink.terminal == .done(.cancelled))
        #expect(backend.calls.withLock { $0 }.isEmpty, "no recogniser was opened")
    }
}
