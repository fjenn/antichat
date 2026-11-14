// AT-206 part 4 / M2.T15 DoD (R-206 AC5, NFR-C7, contract 7): opening a chat of a mode requests that mode's chat
// slot from the scheduler; Evil chats never load `chat_fast` and never get a stand-in; the swap plan is warm when
// the target is resident, else cold (which chat models unload).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct ModeSwapTests {
    let normal = Synth.slot("chat-9b-q4", 5.6)
    let evil = Synth.slot("evil-9b", 6.0, .llama)
    let fast = Synth.slot("chat-0.8b", 0.7)

    @Test func evilNeverLoadsChatFast() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(9.5))
        let swap = ModeSwap(scheduler: s)
        // Normal not ready yet: the starter serves Normal (R-203) …
        let n = try await swap.newChat(mode: .normal, slots: ModeSlots(normal: normal, evil: evil, fastFirst: fast), normalReady: false)
        #expect(n.key == "chat-0.8b")
        await s.release(n)
        // … but never Evil, ready or not.
        let e = try await swap.newChat(mode: .evil, slots: ModeSlots(normal: normal, evil: evil, fastFirst: fast), normalReady: false)
        #expect(e.key == "evil-9b")
        await s.release(e)
        // No Evil slot: refused with evil.notAvailablePack, nothing loaded in its place.
        let before = loader.events
        await #expect(throws: AntiChatError.self) {
            _ = try await swap.newChat(mode: .evil, slots: ModeSlots(normal: normal, evil: nil, fastFirst: fast))
        }
        #expect(loader.events == before)
        do {
            _ = try ModeSwap.slot(for: .evil, slots: ModeSlots(normal: normal, evil: fast, fastFirst: fast))
            Issue.record("chat_fast accepted as the Evil slot")
        } catch let err as AntiChatError {
            #expect(err.userMessageKey == "evil.notAvailablePack")
        }
        #expect(!loader.events.contains("load chat-0.8b") || loader.events.firstIndex(of: "load chat-0.8b")! < loader.events.firstIndex(of: "load evil-9b")!)
    }

    @Test func coldSwapT1UnloadsNormalThenLoadsEvil() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)
        var p = Synth.policy(9.5)
        p.warmSecondVariant = false
        await s.setPolicy(p)
        let swap = ModeSwap(scheduler: s)
        let slots = ModeSlots(normal: normal, evil: evil, fastFirst: fast)
        let n = try await swap.newChat(mode: .normal, slots: slots)
        await s.release(n)
        #expect(ModeSwap.plan(resident: await s.resident, target: evil, warm: false, budget: 9_500_000_000)
                == .cold(unload: ["chat-9b-q4"], load: "evil-9b"))
        let e = try await swap.newChat(mode: .evil, slots: slots)
        #expect(e.loadTime != nil)
        await s.release(e)
        #expect(loader.events == ["load chat-9b-q4", "unload chat-9b-q4", "load evil-9b"])
    }

    @Test func warmPlanOnT3() async throws {
        let s = ModelScheduler(loader: FakeLoader(), clock: ManualClock().fn)
        var p = Synth.policy(48, lowTier: false)
        p.warmSecondVariant = true
        await s.setPolicy(p)
        let swap = ModeSwap(scheduler: s)
        let slots = ModeSlots(normal: Synth.slot("chat-35b-q4", 21.8), evil: Synth.slot("evil-35b-q4", 21.8))
        for m in [ChatModeKind.normal, .evil] {
            let t = try await swap.newChat(mode: m, slots: slots)
            await s.release(t)
        }
        #expect(ModeSwap.plan(resident: await s.resident, target: slots.normal!, warm: true, budget: 48_000_000_000) == .warm("chat-35b-q4"))
        let back = try await swap.newChat(mode: .normal, slots: slots)
        #expect(back.loadTime == nil, "warm hit: no load")
        await s.release(back)
    }

    @Test func modeKinds() {
        #expect(ChatModeKind.normal.other == .evil)
        #expect(ChatModeKind.evil.other == .normal)
    }
}
