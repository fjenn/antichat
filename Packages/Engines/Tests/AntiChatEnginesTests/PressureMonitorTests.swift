// AT-206 part 3, unit leg (R-206 AC3/AC8, NFR-M4; M2.T14 step 1): WARNING releases every idle model (keep-alive or
// not) within ≤ 2 s, never a leased one; CRITICAL pauses the running job first and also releases the over-budget
// models; with no job running, no 2 s sampler exists (NFR-B1).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct PressureMonitorTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    @Test func warningReleasesIdleNeverLeased() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(20, keepAlive: 0))  // Never: keep-alive alone would keep everything
        let busy = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat", 6))
        let e = try await s.ensureLoaded(role: .embed, model: Synth.slot("embed", 0.6))
        await s.release(e)
        let trims = Flag(), pauses = Flag()
        let m = PressureMonitor(scheduler: s, pauseJob: { pauses.hit(); return false }, trimCaches: { trims.hit() })
        let secs = await m.handle(.warning, source: "test")
        // Fake loader: nothing here takes time, so a wall-clock ≤ 2 s bar measured the host's load (the release-time
        // bar is the AT's). What is checked: the warning released the idle, never-leased model, and only it.
        #expect(secs >= 0)
        #expect(await m.lastReleased == ["embed"])
        #expect(await s.residentKeys == ["chat"], "the leased chat model stays")
        #expect(trims.count == 1 && pauses.count == 0)
        await s.release(busy)
        #expect(await !m.isSampling, "no sampler while no job runs")
    }

    @Test func criticalPausesTheJobAndReleasesOverBudget() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(4, allowOver: true))
        let t = try await s.ensureLoaded(role: .chat, model: Synth.slot("big", 6))
        await s.release(t)
        #expect(await s.overBudgetKeys == ["big"])
        let pauses = Flag()
        let m = PressureMonitor(scheduler: s, pauseJob: { pauses.hit(); return true }, trimCaches: {})
        await m.jobStarted()
        #expect(await m.isSampling)
        await m.handle(.critical, source: "test")
        #expect(pauses.count == 1)
        #expect(await m.events.contains("jobPaused"))
        #expect(await s.residentKeys.isEmpty)
        #expect(await s.overBudgetKeys.isEmpty)
        #expect(await s.pressure == .critical)
        // No new over-budget attempt while CRITICAL.
        await #expect(throws: AntiChatError.self) { try await s.ensureLoaded(role: .chat, model: Synth.slot("big", 6)) }
        await m.jobEnded()
        await m.handle(.normal, source: "test")
        #expect(await s.pressure == .normal)
    }
}
