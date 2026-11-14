// M1.T05 step 4: the helper idles out after the last session once nothing is resident.
import Foundation
import os
import Testing
@testable import AntiChatEngineHost

@Suite struct HelperLifecycleTests {
    final class Flags: Sendable {
        let exits = OSAllocatedUnfairLock(initialState: 0)
        let idle = OSAllocatedUnfairLock(initialState: true)
    }

    @Test func exitsAfterTheLastSessionWhenIdle() async throws {
        let f = Flags()
        let l = HelperLifecycle(idleSeconds: 0.05, isIdle: { f.idle.withLock { $0 } }, exitProcess: { f.exits.withLock { $0 += 1 } })
        await l.sessionOpened()
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.exits.withLock { $0 } == 0, "never while a session is open")
        await l.sessionClosed()
        // Progress, not a fixed 200 ms (a loaded host fires the 50 ms idle timer later): it exits, exactly once.
        for _ in 0..<3000 where f.exits.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.exits.withLock { $0 } == 1)
    }

    @Test func waitsWhileAModelIsResidentAndCancelsOnReconnect() async throws {
        let f = Flags()
        f.idle.withLock { $0 = false }
        let l = HelperLifecycle(idleSeconds: 0.05, isIdle: { f.idle.withLock { $0 } }, exitProcess: { f.exits.withLock { $0 += 1 } })
        await l.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.exits.withLock { $0 } == 0, "resident model keeps the helper alive")
        await l.sessionOpened()
        f.idle.withLock { $0 = true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.exits.withLock { $0 } == 0, "a new session cancels the idle timer")
    }
}
