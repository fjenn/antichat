// M2.T09 step 3 (R-204 AC5; E.2.5): retry delays after connection failures — 1 s, 2 s, 4 s … capped at 60 s — and the
// notice after three failures in a row: `download.pausedConnection` ("Download paused — check your connection") with
// [Retry]. Any finished file resets the count. Source fallback (404/410 → next source) is the transfer engine's (T08).
import Foundation

public struct Backoff: Sendable, Equatable {
    public static let cap: Double = 60
    public static let noticeAfter = 3

    /// Consecutive failures since the last success.
    public private(set) var failures = 0

    public init() {}

    /// Delay before retry number `n` (1-based): 2^(n−1) s, ≤ 60 s.
    public static func delay(after n: Int) -> Double { min(cap, pow(2, Double(max(1, n) - 1))) }

    /// Records a failure; returns the delay before the next try.
    public mutating func failed() -> Double {
        failures += 1
        return Self.delay(after: failures)
    }

    public mutating func succeeded() { failures = 0 }

    /// Show "Download paused — check your connection" [Retry].
    public var showsPausedNotice: Bool { failures >= Self.noticeAfter }
}
