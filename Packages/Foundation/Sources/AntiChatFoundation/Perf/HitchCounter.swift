// Main-thread hitch counter while a reply streams (M1.T26 step 1; NFR-U5 "no frame > 33 ms on the main thread").
// A display link (`NSView.displayLink(target:selector:)`, macOS 14+, the CADisplayLink equivalent) delivers one
// callback per screen refresh on the main run loop; a gap between two callbacks > 33 ms means the main thread
// missed frames. Streaming code calls `noteActive` on every reveal; the counter runs while the last activity is
// < 0.5 s old, then closes the session: one `hitch` signpost event per long frame and a `hitchSession` perf-log
// record (frames, hitches, longest frame).
//
// Off unless the perf log is on (`PerfRecorder.isEnabled`) or a test calls `start`, so production pays one Bool.
// The display link comes from a factory closure so this module stays free of AppKit (the UI passes
// `view.displayLink(target:selector:)`).
import Foundation
import QuartzCore

/// Pure frame-gap accounting (unit-tested without a display).
public struct HitchAccumulator: Sendable, Equatable {
    public var thresholdMs: Double
    public private(set) var frames = 0
    public private(set) var hitches = 0
    public private(set) var longestMs: Double = 0
    public private(set) var hitchDurationsMs: [Double] = []
    private var lastTimestamp: Double?

    public init(thresholdMs: Double = 33) { self.thresholdMs = thresholdMs }

    /// Feeds one display-link timestamp (seconds). Returns the frame interval in ms when it is a hitch.
    @discardableResult
    public mutating func tick(_ timestamp: Double) -> Double? {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return nil }
        let ms = (timestamp - last) * 1000
        guard ms >= 0 else { return nil }
        frames += 1
        longestMs = max(longestMs, ms)
        guard ms > thresholdMs else { return nil }
        hitches += 1
        hitchDurationsMs.append(ms)
        return ms
    }

    /// Starts a new gap measurement without counting the pause in between (e.g. after inactivity).
    public mutating func resetClock() { lastTimestamp = nil }
}

@MainActor
public final class HitchCounter: NSObject {
    public static let shared = HitchCounter()

    public struct Session: Sendable, Equatable {
        public var frames: Int
        public var hitches: Int
        public var longestMs: Double
        public var durationS: Double
    }

    /// Seconds without `noteActive` after which a streaming session ends.
    public var idleTimeout: Double = 0.5
    public private(set) var accumulator = HitchAccumulator()
    public private(set) var lastSession: Session?
    /// Forced on by tests / probes regardless of the perf log.
    public var forceEnabled = false

    private var link: CADisplayLink?
    private var lastActive: Double = 0
    private var sessionStart: Double = 0

    public var isRunning: Bool { link != nil }

    /// Called on each streamed reveal. `makeLink` is invoked only when a session starts.
    public func noteActive(_ makeLink: (_ target: Any, _ selector: Selector) -> CADisplayLink?) {
        guard forceEnabled || PerfRecorder.isEnabled else { return }
        lastActive = CACurrentMediaTime()
        guard link == nil else { return }
        guard let l = makeLink(self, #selector(tick(_:))) else { return }
        accumulator = HitchAccumulator()
        sessionStart = lastActive
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if let ms = accumulator.tick(now) {
            Signposts.event(.hitch, value: ms)
        }
        if CACurrentMediaTime() - lastActive > idleTimeout { finish() }
    }

    /// Ends the current session (also called by the idle timeout) and returns it.
    @discardableResult
    public func finish() -> Session? {
        guard let l = link else { return nil }
        l.invalidate()
        link = nil
        let s = Session(frames: accumulator.frames, hitches: accumulator.hitches, longestMs: accumulator.longestMs,
                        durationS: max(0, CACurrentMediaTime() - sessionStart))
        lastSession = s
        PerfRecorder.record("hitchSession", kind: .event, durationNs: UInt64(s.durationS * 1e9), meta: [
            "frames": String(s.frames), "hitches": String(s.hitches), "longest_ms": String(format: "%.2f", s.longestMs),
        ])
        return s
    }
}
