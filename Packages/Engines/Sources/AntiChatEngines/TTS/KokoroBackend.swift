// M3.T07 step 3 (R-054; P-media-04): Kokoro 82M read aloud. The `tts` slot loads through the scheduler (one load
// authority) as `KokoroTTS` (FluidAudio 0.18.0 `KokoroAneManager`, ANE, af_heart) from the model store; each chunk is
// synthesised with `synthesizeDetailed` (speed = the user rate) while the previous one plays, so only the first
// chunk's synthesis is on the click → first-audio path (NFR-V8). PCM goes to `TTSPlayback`; `.started(chunk)` fires
// when the chunk's first sample is handed to the output (`tts.firstSample` signpost for the first), `.played(ms)`
// follows the playback clock, `onSynthesized` feeds the ChunkTable (word offsets by character share: the ANE chain
// returns per-token frame durations, not word timings). `stop()` stops the player at once (≤ 200 ms, R-054 AC1).
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatFoundation
import FluidAudio
import Foundation
import Synchronization
import os

/// The audio sink behind Kokoro: the speakers (AVAudioEngine player node) or a silent clock (tests, perf probes).
public final class TTSPlayback: @unchecked Sendable {
    public enum Output: Sendable { case speakers, silent }
    public let output: Output
    private let out: PlaybackOut?
    /// M3.T10: a voice conversation's own output (the session's VPIO graph or its silent clock).
    private let sink: (any VoiceOutputSink)?
    private let state = Mutex<(scheduled: Int, startedAt: ContinuousClock.Instant?, rate: Int)>((0, nil, 24_000))

    public init(output: Output) {
        self.output = output
        out = output == .speakers ? PlaybackOut() : nil
        sink = nil
    }

    public init(sink: any VoiceOutputSink) {
        output = .silent
        out = nil
        self.sink = sink
    }

    public func prepare(sampleRate: Int) throws {
        state.withLock { $0.rate = sampleRate }
        try out?.prepare(sampleRate: sampleRate, volume: 1)
        try sink?.prepare(sampleRate: sampleRate)
    }

    /// Hands `samples` to the output; returns the sample offset they start at.
    @discardableResult
    public func schedule(_ samples: [Float]) -> Int {
        if let sink {
            let at = sink.scheduledSamples
            sink.schedule(samples)
            return at
        }
        out?.schedule(samples)
        return state.withLock { s in
            defer { s.scheduled += samples.count }
            if s.startedAt == nil { s.startedAt = .now }
            return s.scheduled
        }
    }

    /// Samples played so far (the playback clock: wall time since the first buffer, capped at what was scheduled).
    public var playedSamples: Int {
        if let sink { return sink.playedSamples }
        return state.withLock { s in
            guard let t = s.startedAt else { return 0 }
            let d = ContinuousClock.now - t
            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            return min(s.scheduled, Int(secs * Double(s.rate)))
        }
    }

    public var scheduledSamples: Int { sink?.scheduledSamples ?? state.withLock { $0.scheduled } }
    /// Audio handed over that has not played yet (M3 review P1-4: a conversation's sink answers from its device).
    public var hasPendingAudio: Bool { sink?.hasPendingAudio ?? (playedSamples < scheduledSamples) }
    /// The chunk stream ended: a tail held back by the output's prebuffer plays now.
    public func endOfInput() { sink?.endOfInput() }
    public var sampleRate: Int { sink?.sampleRate ?? state.withLock { $0.rate } }

    public func stop() {
        sink?.flush()
        out?.stopPlayer()
        state.withLock { $0 = (0, nil, $0.rate) }
    }
}

public final class KokoroBackend: TTSBackend, @unchecked Sendable {
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "voice")
    private let tts: any SpeechSynthesizing
    let playback: TTSPlayback
    private let stopped = Mutex(false)
    /// The current reply's event stream until its `.finished` is out (nil after): `stop()` ends the reply itself.
    private let events = Mutex<(reply: UUID, cont: AsyncStream<TTSEvent>.Continuation)?>(nil)
    private let synthesizedHook = Mutex<(@Sendable (TTSChunk, Int) -> Void)?>(nil)
    private let wordHook = Mutex<(@Sendable (TTSChunk, Int, [Int]?) -> Void)?>(nil)
    /// M3.T10: each chunk once synthesised with its word start offsets (Kokoro's predicted durations), for spans.
    public var onSynthesizedWords: (@Sendable (TTSChunk, Int, [Int]?) -> Void)? {
        get { wordHook.withLock { $0 } }
        set { wordHook.withLock { $0 = newValue } }
    }
    /// Each chunk once synthesised: (chunk, sample count). Locked: set by the caller, read by the speech task.
    public var onSynthesized: (@Sendable (TTSChunk, Int) -> Void)? {
        get { synthesizedHook.withLock { $0 } }
        set { synthesizedHook.withLock { $0 = newValue } }
    }

    public init(tts: any SpeechSynthesizing, output: TTSPlayback.Output = .speakers) {
        self.tts = tts
        playback = TTSPlayback(output: output)
    }

    /// M3.T10: a voice turn's reply into the session's output.
    public init(tts: any SpeechSynthesizing, playback: TTSPlayback) {
        self.tts = tts
        self.playback = playback
    }

    public var voices: [VoiceInfo] { KokoroVoices.english.map { VoiceInfo(id: $0.id, name: $0.name, language: $0.language) } }

    public func speak(_ chunks: AsyncStream<TTSChunk>, voice: String, rate: Float) -> AsyncStream<TTSEvent> {
        stopped.withLock { $0 = false }
        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()
        let reply = UUID()
        events.withLock { $0 = (reply, cont) }
        // Events go out only while this reply has not finished: after `stop()` sent `.finished` nothing follows it.
        let send: @Sendable (TTSEvent) -> Void = { [self] e in
            events.withLock { if let c = $0, c.reply == reply { c.cont.yield(e) } }
        }
        let speed = min(1.5, max(0.75, rate))
        let task = Task { [self] in
            var starts: [(chunk: Int, at: Int)] = []
            var announced = 0
            var prepared = false
            var failed = false
            // Synthesis runs ahead of playback; a clock task reports starts and played time.
            let clock = Task { [playback] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    send(.played(ms: Double(playback.playedSamples) / Double(playback.sampleRate) * 1000))
                }
            }
            for await chunk in chunks {
                if stopped.withLock({ $0 }) || Task.isCancelled { break }
                guard let audio = try? await tts.synthesize(chunk.text, voice: voice.isEmpty ? nil : voice, speed: speed), !audio.samples.isEmpty else {
                    failed = true
                    break
                }
                if stopped.withLock({ $0 }) { break }
                if !prepared {
                    do { try playback.prepare(sampleRate: audio.sampleRate) } catch { failed = true; break }
                    prepared = true
                }
                onSynthesized?(chunk, audio.samples.count)
                onSynthesizedWords?(chunk, audio.samples.count, audio.wordStarts)
                let at = playback.schedule(audio.samples)
                starts.append((chunk.index, at))
                if announced == 0 { Self.signposter.emitEvent("tts.firstSample") }
                // Announce every chunk whose start the clock has reached (the first one at once).
                while announced < starts.count, starts[announced].at <= playback.playedSamples {
                    send(.started(chunk: starts[announced].chunk))
                    announced += 1
                }
            }
            // Drain: wait for the scheduled audio to play out, announcing the remaining starts (M3 review P1-4: the
            // output owes nothing more — a stall or a lost graph cannot keep the reply "speaking" forever).
            if !failed { playback.endOfInput() }
            while !stopped.withLock({ $0 }), !Task.isCancelled, !failed, playback.hasPendingAudio {
                while announced < starts.count, starts[announced].at <= playback.playedSamples {
                    send(.started(chunk: starts[announced].chunk))
                    announced += 1
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            while announced < starts.count, !stopped.withLock({ $0 }), !failed {
                send(.started(chunk: starts[announced].chunk))
                announced += 1
            }
            clock.cancel()
            let played = Double(playback.playedSamples) / Double(playback.sampleRate) * 1000
            let wasStopped = stopped.withLock { $0 } || Task.isCancelled || failed
            events.withLock {  // unless `stop()` already finished the reply
                guard let c = $0, c.reply == reply else { return }
                c.cont.yield(.played(ms: played))
                c.cont.yield(.finished(stopped: wasStopped))
                $0 = nil
            }
            // The stream ends only here, once synthesis is over (a caller releases the model lease at its end).
            cont.finish()
            // An external `stop()` already flushed; flushing again here could wipe the next reply's audio on a shared
            // sink (M3 review finding 12c).
            if !stopped.withLock({ $0 }) { playback.stop() }
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Silences the output at once and finishes the reply right here (`.played` = what was heard, then
    /// `.finished(stopped: true)`), so the stop reaches the caller without waiting for the speech task to be
    /// scheduled again (R-054 AC1, ≤ 200 ms: a loaded host delayed that wake-up). The stream itself ends when the
    /// speech task has wound down (an in-flight chunk synthesis completes first).
    public func stop() {
        stopped.withLock { $0 = true }
        let played = Double(playback.playedSamples) / Double(max(1, playback.sampleRate)) * 1000
        playback.stop()
        events.withLock {
            guard let c = $0 else { return }
            c.cont.yield(.played(ms: played))
            c.cont.yield(.finished(stopped: true))
            $0 = nil
        }
    }

    /// K-NEW-ENG-9: Kokoro's Core ML chain crashes on macOS 26.4–26.5; those systems read aloud with the system voice
    /// (logged once as `tts.osGate`) until a re-test there passes.
    public static func osAllowsKokoro(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        !(v.majorVersion == 26 && (v.minorVersion == 4 || v.minorVersion == 5))
    }
}
