// AT-NFR-R5 / R-206 AC6 (M2.T13 step 4): without "Allow loads above the memory budget" nothing loads past B; with it
// the refusal becomes a guarded attempt (recorded as over budget, released first at CRITICAL), and no attempt starts
// while the pressure is already CRITICAL.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct OverBudgetRefusalTests {
    @Test func defaultRefusesAndOverrideAttempts() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(4.0))
        let big = Synth.slot("chat-9b-q4", 6.5)
        await #expect(throws: AntiChatError.self) { try await s.ensureLoaded(role: .chat, model: big) }
        #expect(loader.loaded.isEmpty)
        await s.setPolicy(Synth.policy(4.0, allowOver: true))
        let t = try await s.ensureLoaded(role: .chat, model: big)
        #expect(loader.loaded == ["chat-9b-q4"])
        #expect(await s.overBudgetKeys == ["chat-9b-q4"])
        await s.release(t)
        #expect(BudgetOverride.criticalVictims(overBudget: await s.overBudgetKeys) == ["chat-9b-q4"])
        _ = await s.evict("chat-9b-q4")
        #expect(await s.overBudgetKeys.isEmpty)
    }

    @Test func noAttemptAtCriticalPressure() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(4.0, allowOver: true))
        await s.setPressure(.critical)
        await #expect(throws: AntiChatError.self) { try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 6.5)) }
        #expect(loader.loaded.isEmpty)
        #expect(!BudgetOverride.mayAttempt(allowOverBudget: false, pressure: .normal))
    }
}
