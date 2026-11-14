// Waiting for a child `Process` to end without `waitUntilExit()` (fix/resume-hang).
//
// `waitUntilExit()` parks the calling thread in its run loop (no timeout) until Foundation wakes it. Called from a
// Swift-concurrency test that `run()` the child on one pool thread and, after an `await`, resumed on another, that
// wake-up can be lost: the child is dead and reaped, `isRunning` is already false, and the test sleeps in `mach_msg`
// forever (ResumeTests in a full `make test-unit`: 19 min at 0 % CPU; reproduced standalone with 6 tasks doing
// spawn → `Task.sleep` → SIGKILL → `waitUntilExit()`, every hung waiter had hopped threads). `isRunning` is updated
// off the run loop, so a bounded poll of it sees the exit; past the bound the test fails with a message, not a hang.
import Foundation

enum ChildExit {
    struct Timeout: Error, CustomStringConvertible { let description: String }

    /// Waits (condition-based, ≤ `limit`) until `p` has exited. Past `limit` the child is SIGKILLed and `Timeout`
    /// is thrown, so a regression fails fast instead of hanging the run.
    static func wait(_ p: Process, _ what: String, limit: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while p.isRunning {
            if clock.now >= deadline { throw timeout(p, what, limit) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The same for synchronous callers.
    static func waitBlocking(_ p: Process, _ what: String, limit: Duration) throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while p.isRunning {
            if clock.now >= deadline { throw timeout(p, what, limit) }
            usleep(5_000)
        }
    }

    private static func timeout(_ p: Process, _ what: String, _ limit: Duration) -> Timeout {
        let pid = p.processIdentifier
        let alive = kill(pid, 0) == 0
        if pid > 1 { kill(pid, SIGKILL) }  // never leave it behind (never pid 0 = our own group, fix/stray-kill)
        let state = alive ? "the child (pid \(pid)) is still alive" : "the child (pid \(pid)) is gone but Foundation never saw it exit"
        return Timeout(description: "\(what): no exit within \(limit); \(state)")
    }
}
