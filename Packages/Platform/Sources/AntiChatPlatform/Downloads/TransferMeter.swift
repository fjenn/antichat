// M0.T10 (S-12) → M2.T08: download meters for the bench and the download tests, fed by `TransferEngine`'s
// `onBytes` hook: the raw byte counter (re-fetched = received − file size, NFR-D6) and the [EMULATED] rate cap.
import Foundation

/// Raw bytes received from the network, across all lanes.
/// `re-fetched = received − file size` (NFR-D6).
public final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    public init() {}
    public func add(_ n: Int) { lock.withLock { value += Int64(n) } }
    public var total: Int64 { lock.withLock { value } }
    public func reset() { lock.withLock { value = 0 } }
}

/// Token bucket shared by every lane (`ANTICHAT_DL_RATE_LIMIT_MBPS`, M0.T10 step 2 no-admin fallback).
/// `consume` blocks the calling URLSession delegate queue until the bytes fit the rate; the stalled
/// delegate back-pressures that lane's TCP connection. Results are labelled `[EMULATED]`.
public final class TokenBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesPerSecond: Double
    private var tokens: Double
    private var last: CFAbsoluteTime
    private let burst: Double
    /// When true every consumer waits (a 100 %-loss window, M0.T10 step 4 "throttle to 0").
    private var blocked = false

    /// `mbps` = megabits per second (10⁶ bit/s). Burst = 50 ms of traffic.
    public init(mbps: Double) {
        bytesPerSecond = mbps * 1_000_000 / 8
        burst = max(64 * 1024, bytesPerSecond * 0.05)
        tokens = burst
        last = CFAbsoluteTimeGetCurrent()
    }

    public func setBlocked(_ b: Bool) { lock.withLock { blocked = b } }

    public func consume(_ n: Int) {
        var need = Double(n)
        while need > 0 {
            let wait: Double = lock.withLock {
                let now = CFAbsoluteTimeGetCurrent()
                tokens = min(burst, tokens + (now - last) * bytesPerSecond)
                last = now
                if blocked { return 0.05 }
                let take = min(need, max(0, tokens))
                tokens -= take
                need -= take
                return need > 0 ? min(0.05, need / bytesPerSecond) : 0
            }
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }
}
