// M4.T04 step 3 (R-291 AC2, P-media-10): the Mac does not idle-sleep while a media job runs.
// `ProcessInfo.beginActivity([.idleSystemSleepDisabled, .userInitiated])` creates a PreventUserIdleSystemSleep
// assertion named "AntiChat media job" (visible in `pmset -g assertions`), held for the job's lifetime and ended when it
// stops. Like every power assertion it dies with the process, so a helper crash never leaves one behind.
import Foundation

public final class SleepAssertion: @unchecked Sendable {
    public static let reason = "AntiChat media job"
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    public init() {}

    deinit { if let token { ProcessInfo.processInfo.endActivity(token) } }

    public var isHeld: Bool { lock.withLock { token != nil } }

    /// Takes the assertion (idempotent).
    public func hold() {
        lock.withLock {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: Self.reason)
        }
    }

    /// Ends it (idempotent).
    public func release() {
        let t = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let t { ProcessInfo.processInfo.endActivity(t) }
    }
}
