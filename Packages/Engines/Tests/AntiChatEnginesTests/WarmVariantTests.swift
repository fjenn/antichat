// AT-206 part 4 (R-206 AC5; M2.T15 step 1, E.2.7 "warm if fits"): on T3+ (SetPolicy.warmSecondVariant = true) the other
// mode's chat model stays loaded beside the current one when both fit B, and is the first chat model to go when they
// do not; with the flag off (T0–T2, or FeatureFlag.warmSecondVariant off) the other chat model always unloads first.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct WarmVariantTests {
    func policy(_ b: Double, warm: Bool?) -> SetPolicy {
        var p = Synth.policy(b, lowTier: false)
        p.warmSecondVariant = warm
        return p
    }

    @Test func warmKeepsBothWhenTheyFitB() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)  // default capacity: MLX 1
        await s.setPolicy(policy(48, warm: true))
        #expect(await s.capacity[.mlx] == 2)
        let n = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-35b-q4", 21.8))
        await s.release(n)
        let e = try await s.ensureLoaded(role: .chat, model: Synth.slot("evil-35b-q4", 21.8))
        await s.release(e)
        #expect(await s.residentKeys == ["chat-35b-q4", "evil-35b-q4"])
        // Back to Normal: a warm hit, nothing loads.
        let before = loader.events.count
        let n2 = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-35b-q4", 21.8))
        #expect(n2.loadTime == nil)
        #expect(loader.events.count == before)
        await s.release(n2)
    }

    @Test func warmDoesNotFitSoTheSecondVariantGoes() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        await s.setPolicy(policy(36, warm: true))  // T3-48: 2 × 21.8 GB > 36 GB
        let n = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-35b-q4", 21.8))
        await s.release(n)
        let e = try await s.ensureLoaded(role: .chat, model: Synth.slot("evil-35b-q4", 21.8))
        await s.release(e)
        #expect(await s.residentKeys == ["evil-35b-q4"])
    }

    @Test func secondVariantIsFirstChatToGoUnderPressure() async throws {
        let clock = ManualClock()
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: clock.fn)
        await s.setPolicy(policy(48, warm: true))
        for k in ["stt", "chat-35b-q4", "evil-35b-q4"] {
            clock.advance(1)
            let t = try await s.ensureLoaded(role: k == "stt" ? .stt : .chat, model: Synth.slot(k, k == "stt" ? 1 : 21.8))
            await s.release(t)
        }
        let order = EvictionPolicy.order(await s.resident).map(\.key)
        #expect(order.first == "chat-35b-q4", "the older chat model is the second variant, before STT")
    }

    @Test func coldWithFlagOffUnloadsTheOtherChatEvenAcrossEngines() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        await s.setPolicy(policy(48, warm: false))  // both would fit B and differ in engine — still unload → load
        let n = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 5.6))
        await s.release(n)
        let e = try await s.ensureLoaded(role: .chat, model: Synth.slot("evil-9b", 6.0, .llama))
        await s.release(e)
        #expect(await s.residentKeys == ["evil-9b"])
        #expect(loader.events == ["load chat-9b-q4", "unload chat-9b-q4", "load evil-9b"], "unload before load (NFR-M1)")
        #expect(await s.log.contains("modeSwap chat-9b-q4"))
    }

    @Test func coldNeverUnloadsALeasedChat() async throws {
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(policy(48, warm: false))
        let n = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 5.6))  // a reply is streaming
        let e = try await s.ensureLoaded(role: .chat, model: Synth.slot("evil-9b", 6.0, .llama))
        #expect(await s.residentKeys == ["chat-9b-q4", "evil-9b"])
        await s.release(n)
        await s.release(e)
    }

    @Test func unsetPolicyKeepsThePlainBudgetPlan() async throws {
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(48))
        for k in ["a", "b"] {
            let t = try await s.ensureLoaded(role: .chat, model: Synth.slot(k, 5))
            await s.release(t)
        }
        #expect(await s.residentKeys == ["a", "b"], "benches and older senders: E.2.7 budget plan only")
    }

    @Test func pureRules() {
        #expect(WarmVariant.keepsWarm(currentBytes: 21_800_000_000, otherBytes: 21_800_000_000, budget: 48_000_000_000))
        #expect(!WarmVariant.keepsWarm(currentBytes: 21_800_000_000, otherBytes: 21_800_000_000, budget: 36_000_000_000))
        #expect(WarmVariant.capacity(base: EvictionPolicy.defaultCapacity, warm: false)[.mlx] == 1)
        #expect(WarmVariant.capacity(base: EvictionPolicy.defaultCapacity, warm: true)[.mlx] == 2)
    }
}
