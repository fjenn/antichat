// M3.T10 (R-282 AC2, NFR-V3): where a voice conversation's TTS goes and how much of it was heard.
//   `DuplexOutputSink`: the session's own VPIO graph (`VoiceAudioEngine`, the player node is the echo reference,
//   M3.T09 step 1); the played clock is the vendored agent-squad `PlaybackClock` fed by each ~100 ms buffer's
//   `.dataPlayedBack` callback (UP-SS-007), so a stop reads what really left the speakers.
//   `ClockedSilentSink`: no device (tests, perf probes, mode inject [IN-PIPELINE]); a virtual playhead advances in real
//   time only while audio is queued and the output is not paused, so a synthesis underrun or a pause is never counted
//   as heard.
// Both pause in place (barge-in candidate), resume (false alarm) and flush (confirmed barge-in / end).
// M3 review P1-4: the duplex sink's played clock is one monotonic count per reply: a stall (the queue ran dry while
// the next chunk was synthesised, e.g. around a tool call) no longer restarts it at 0, and a graph rebuild (route
// change) re-bases it to what was played and drops the lost remainder, so `playedSamples` always reaches
// `scheduledSamples` and the reply finishes. `hasPendingAudio` = buffers still owed a played callback;
// `endOfInput` starts a short tail still in the device's prebuffer. Speaker mute is the output volume (P1-3).
import AgentSquadVendored
import Foundation
import Synchronization

public protocol VoiceOutputSink: AnyObject, Sendable {
    func prepare(sampleRate: Int) throws
    func schedule(_ samples: [Float])
    /// Samples heard since the last flush.
    var playedSamples: Int { get }
    /// Samples handed over since the last flush.
    var scheduledSamples: Int { get }
    var sampleRate: Int { get }
    func pause()
    func resume()
    /// Drops queued audio and silences the output now; counters restart at 0.
    func flush()
    /// Speaker mute: the audio keeps playing silently, so the clock (and the spoken span) still advance.
    func setMuted(_ muted: Bool)
    /// Audio handed over that has not played yet (a paused output keeps it pending).
    var hasPendingAudio: Bool { get }
    /// Nothing more is coming for now (the reply's text is complete): play what is still held back.
    func endOfInput()
}

extension VoiceOutputSink {
    public var hasPendingAudio: Bool { playedSamples < scheduledSamples }
    public func endOfInput() {}
}

public final class ClockedSilentSink: VoiceOutputSink, @unchecked Sendable {
    private struct S {
        var rate = 24_000
        var scheduled = 0
        var playhead = 0.0
        var last: ContinuousClock.Instant?
        var paused = false
    }
    private let s = Mutex(S())

    public init() {}

    public func prepare(sampleRate: Int) throws { s.withLock { $0.rate = sampleRate } }

    private static func advance(_ st: inout S) {
        let now = ContinuousClock.now
        defer { st.last = now }
        guard let last = st.last, !st.paused else { return }
        let d = now - last
        let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        st.playhead = min(Double(st.scheduled), st.playhead + secs * Double(st.rate))
    }

    public func schedule(_ samples: [Float]) {
        s.withLock { st in
            Self.advance(&st)
            st.scheduled += samples.count
        }
    }

    public var playedSamples: Int { s.withLock { st in Self.advance(&st); return Int(st.playhead) } }
    public var scheduledSamples: Int { s.withLock { $0.scheduled } }
    public var sampleRate: Int { s.withLock { $0.rate } }
    public func pause() { s.withLock { st in Self.advance(&st); st.paused = true } }
    public func resume() { s.withLock { st in Self.advance(&st); st.paused = false } }
    public func flush() { s.withLock { st in st = S(rate: st.rate) } }
    public func setMuted(_ muted: Bool) {}
}

/// The output device behind `DuplexOutputSink`: the session's VPIO graph (`VoiceAudioEngine`), a model of it in tests.
public protocol VoicePlaybackDevice: AnyObject, Sendable {
    /// Queues `samples`; `onPlayed` once they played (never for flushed or lost ones). False: not queued (no graph).
    @discardableResult func schedulePlayback(_ samples: [Float], onPlayed: (@Sendable () -> Void)?) -> Bool
    func pausePlayback()
    func resumePlayback()
    func flushPlayback()
    func setPlaybackVolume(_ volume: Float)
    /// Starts a burst still waiting for the prebuffer target.
    func playPrebuffered()
    /// Set by the sink: every queued buffer was lost (graph rebuilt after a route / device change).
    var onPlaybackReset: (@Sendable () -> Void)? { get set }
}

public final class DuplexOutputSink: VoiceOutputSink, @unchecked Sendable {
    private let audio: any VoicePlaybackDevice
    /// Counts one burst of played buffers (agent-squad); the sink adds the bursts of a reply (`baseMs`).
    private let clock = PlaybackClock()
    private struct S {
        var rate = 24_000
        var scheduled = 0
        /// Played time of the reply's earlier bursts (the clock restarts at 0 when its queue ran empty).
        var baseMs = 0.0
        /// Buffers queued whose played callback is still owed (this generation).
        var pending = 0
        /// Bumped by a flush or a graph reset: callbacks of older buffers are ignored.
        var generation = 0
    }
    private let s = Mutex(S())
    static let sliceMs = 100

    public init(audio: any VoicePlaybackDevice) {
        self.audio = audio
        audio.onPlaybackReset = { [weak self] in self?.rebase() }
    }

    public func prepare(sampleRate: Int) throws { s.withLock { $0.rate = sampleRate } }

    public func schedule(_ samples: [Float]) {
        let rate = s.withLock { $0.rate }
        let slice = max(1, rate * Self.sliceMs / 1_000)
        var i = 0
        while i < samples.count {
            let piece = Array(samples[i..<min(i + slice, samples.count)])
            let ms = Double(piece.count) * 1_000 / Double(rate)
            // Under the sink lock (the callbacks complete the clock under it too): with nothing pending the clock is
            // idle and `willSchedule` restarts its burst at 0, so its played time moves into `baseMs` first.
            let (token, generation) = s.withLock { st -> (Int, Int) in
                if st.pending == 0 { st.baseMs += clock.milliseconds() }
                let t = clock.willSchedule()
                st.scheduled += piece.count
                st.pending += 1
                return (t, st.generation)
            }
            let queued = audio.schedulePlayback(piece) { [weak self] in
                self?.played(ms: ms, token: token, generation: generation)
            }
            if !queued {  // no graph (mid-rebuild): never played, so never counted
                s.withLock { st in
                    guard st.generation == generation else { return }
                    clock.completed(durationMs: 0, token: token)
                    st.scheduled -= piece.count
                    st.pending -= 1
                }
            }
            i += slice
        }
    }

    private func played(ms: Double, token: Int, generation: Int) {
        s.withLock { st in
            guard st.generation == generation else { return }
            clock.completed(durationMs: ms, token: token)
            st.pending -= 1
        }
    }

    public var playedSamples: Int {
        s.withLock { st in min(st.scheduled, Int((st.baseMs + clock.milliseconds()) * Double(st.rate) / 1_000)) }
    }

    public var scheduledSamples: Int { s.withLock { $0.scheduled } }
    public var sampleRate: Int { s.withLock { $0.rate } }
    public var hasPendingAudio: Bool { s.withLock { $0.pending > 0 } }
    public func pause() { audio.pausePlayback() }
    public func resume() { audio.resumePlayback() }
    public func endOfInput() { audio.playPrebuffered() }

    public func flush() {
        audio.flushPlayback()
        s.withLock { st in
            clock.flushed()
            clock.reset()
            st = S(rate: st.rate, generation: st.generation + 1)
        }
    }

    /// The graph was rebuilt: what played stays played, the queued rest is gone (not heard, not owed).
    private func rebase() {
        s.withLock { st in
            st.baseMs += clock.milliseconds()
            clock.reset()
            st.scheduled = min(st.scheduled, Int(st.baseMs * Double(st.rate) / 1_000))
            st.pending = 0
            st.generation += 1
        }
    }

    public func setMuted(_ muted: Bool) { audio.setPlaybackVolume(muted ? 0 : 1) }
}
