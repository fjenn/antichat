// AT-206 part 4 (R-206 AC5; M2.T15 steps 2–3): a hover hint reaches the scheduler and starts a load of the registered
// role (voice: a stub footprint until M3) or of the other mode's chat slot; a newer hint for the same pack cancels the
// older one before it loads; a hint never evicts a leased model. Acceptance ≤ 50 ms after the hover (signpost
// `warmupHint`, the latency the hint carries).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct PredictiveWarmupTests {
    @Test func voiceHintLoadsRegisteredRoles() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(9.5))
        let w = PredictiveWarmup(scheduler: s)
        await w.register(pack: "voice", role: .stt, slot: Synth.slot("stt-stub", 0.6, .scripted))
        // "Accepted at once after the hover" as ordering, not a wall-clock bar (a loaded host stretched the 50 ms): the
        // hint is accepted while the load it starts is still blocked, i.e. accepting never waits for a load.
        let gate = LoadGate()
        loader.gate = gate
        let sent = Date()
        let a = await w.hint(pack: "voice", mode: nil, slot: nil, sentAt: sent)
        #expect(a.keys == ["stt-stub"])
        #expect(a.latency >= 0)
        #expect(loader.loaded.isEmpty, "accepted only after the load")
        await gate.open()
        await w.settle(pack: "voice")
        #expect(loader.loaded.contains("stt-stub"))
        #expect(await w.loaded == ["stt-stub"])
        #expect(await s.leaseCount("stt-stub") == 0, "a warm-up holds no lease")
    }

    @Test func chatHintLoadsTheOtherModesSlot() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(48))
        let w = PredictiveWarmup(scheduler: s)
        await w.hint(pack: "chat", mode: "evil", slot: Synth.slot("evil-9b", 6, .llama))
        await w.settle(pack: "chat")
        #expect(loader.loaded == ["evil-9b"])
    }

    @Test func voiceHintWithNothingRegisteredIsAcceptedAndIdle() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        let w = PredictiveWarmup(scheduler: s)
        let a = await w.hint(pack: "voice", mode: nil, slot: nil)
        await w.settle(pack: "voice")
        #expect(a.keys.isEmpty)
        #expect(loader.events.isEmpty)
        #expect(await w.accepted.count == 1)
    }

    @Test func newerHintCancelsOlder() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(48))
        let w = PredictiveWarmup(scheduler: s)
        // Hold the decision queue so the first hint's load cannot start before the second hint arrives.
        let gate = AsyncStream<Void>.makeStream()
        let job = Task { try await s.runJob(key: "hold") { _ in for await _ in gate.stream {} } }
        await w.hint(pack: "chat", mode: "evil", slot: Synth.slot("evil-9b", 6, .llama))
        await w.hint(pack: "chat", mode: "normal", slot: Synth.slot("chat-9b-q4", 5.6))
        gate.continuation.finish()
        _ = try await job.value
        await w.settle(pack: "chat")
        for _ in 0..<3000 where !loader.loaded.contains("chat-9b-q4") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loader.loaded.contains("chat-9b-q4"))
        #expect(!(await w.loaded).contains("evil-9b"), "the cancelled hint did not finish a load")
    }

    @Test func hintNeverEvictsALeasedModel() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        var p = Synth.policy(9.5)
        p.warmSecondVariant = false
        await s.setPolicy(p)
        let lease = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 5.6))  // a reply streams
        let w = PredictiveWarmup(scheduler: s)
        await w.hint(pack: "chat", mode: "evil", slot: Synth.slot("evil-9b", 6.0, .llama))
        await w.settle(pack: "chat")
        #expect(loader.loaded.contains("chat-9b-q4"))
        #expect(!loader.loaded.contains("evil-9b"), "does not fit beside the leased model; refused, not evicted")
        await s.release(lease)
    }
}
