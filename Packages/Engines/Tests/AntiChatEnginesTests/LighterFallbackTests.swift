// AT-NFR-R5 unit leg (NFR-R5, R-298; M2.T13 step 3): a load that would exceed B or the free memory is refused before
// loading; the first catalog fallback that fits is used (`usingLighter`); none → `model.notEnoughMemory` (+ Retry),
// and the engine never saw a load.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct LighterFallbackTests {
    func scheduler(_ b: Double, free: UInt64 = .max) async -> (ModelScheduler, FakeLoader) {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setFreeMemory { free }
        await s.setPolicy(Synth.policy(b))
        return (s, loader)
    }

    @Test func lighterFallbackIsUsedWhenTheRequestExceedsB() async throws {
        let (s, loader) = await scheduler(4.0)  // T0
        var big = Synth.slot("chat-9b-q4", 6.5)
        big.fallbacks = [Synth.slot("chat-4b", 4.5), Synth.slot("chat-2b", 2.3), Synth.slot("chat-0.8b", 0.9)]
        let t = try await s.ensureLoaded(role: .chat, model: big)
        #expect(t.slot?.key == "chat-2b", "first fallback that fits")
        #expect(loader.loaded == ["chat-2b"])
        #expect(await s.log.contains("lighter chat-9b-q4 -> chat-2b"))
    }

    @Test func noFallbackRefusesBeforeLoading() async throws {
        let (s, loader) = await scheduler(4.0)
        let big = Synth.slot("chat-9b-q4", 6.5)
        await #expect(throws: AntiChatError.self) { try await s.ensureLoaded(role: .chat, model: big) }
        do { _ = try await s.ensureLoaded(role: .chat, model: big) } catch let e as AntiChatError {
            #expect(e.userMessageKey == "model.notEnoughMemory")
        }
        #expect(loader.events.isEmpty, "no load attempted")
    }

    @Test func freeMemoryBelowTheFootprintAlsoRefuses() async throws {
        let (s, loader) = await scheduler(9.5, free: UInt64(3 * Synth.GB))  // fits B, not what the Mac has free now
        var chat = Synth.slot("chat-9b-q4", 6.5)
        chat.fallbacks = [Synth.slot("chat-2b", 2.3)]
        let t = try await s.ensureLoaded(role: .chat, model: chat)
        #expect(t.slot?.key == "chat-2b")
        #expect(loader.loaded == ["chat-2b"])
    }

    @Test func evilHasNoWeakerStandIn() async throws {
        let (s, loader) = await scheduler(4.0)
        let evil = Synth.slot("evil-9b", 6.45, .llama)  // Evil slots carry no fallback chain (contract 7)
        await #expect(throws: AntiChatError.self) { try await s.ensureLoaded(role: .chat, model: evil) }
        #expect(loader.loaded.isEmpty)
    }
}
