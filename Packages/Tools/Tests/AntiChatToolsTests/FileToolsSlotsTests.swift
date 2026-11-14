// A-M6-T21a (a), M6.T21 close review #5: the slot leaser (app side, fake wipes; the real services are exercised by
// App/IntegrationTests/FileTools/FileToolsSlotTests). One chat per slot; a lease moves only after every variant the
// slot served was wiped and reported its scratch empty; beyond the capacity a chat waits (and is listed as waiting).
@testable import AntiChatTools
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing

@Suite struct FileToolsSlotsTests {
    final class Wipes: @unchecked Sendable {
        let log = Mutex<[String]>([])
        let fail = Mutex<Set<Int>>([])
        var wiper: FileToolsSlots.Wiper {
            { slot, net, _ in
                self.log.withLock { $0.append("\(slot)\(net ? "n" : "")") }
                return !self.fail.withLock { $0.contains(slot) }
            }
        }
        var entries: [String] { log.withLock { $0 } }
        func clear() { log.withLock { $0.removeAll() } }
    }

    @Test func eachChatGetsItsOwnSlotAndKeepsIt() async throws {
        let w = Wipes()
        let s = FileToolsSlots(capacity: 3, wiper: w.wiper)
        let a = try await s.acquire(chatID: "a", network: false)
        let b = try await s.acquire(chatID: "b", network: false)
        #expect(a.slot != b.slot)
        #expect(w.entries.sorted() == ["1", "2"])  // first use of a slot in this process: wiped and verified once
        await s.release(a); await s.release(b)
        w.clear()
        let a2 = try await s.acquire(chatID: "a", network: false)
        #expect(a2.slot == a.slot)
        #expect(w.entries.isEmpty, "the same chat keeps its slot (and its interpreter): no wipe")
        // Two calls of one chat share its slot (the service serialises them).
        let a3 = try await s.acquire(chatID: "a", network: false)
        #expect(a3.slot == a.slot)
        await s.release(a2); await s.release(a3)
    }

    @Test func aLeaseMovesOnlyAfterEveryVariantItServedIsWiped() async throws {
        let w = Wipes()
        let s = FileToolsSlots(capacity: 1, wiper: w.wiper)
        let a = try await s.acquire(chatID: "a", network: false)
        await s.release(a)
        let an = try await s.acquire(chatID: "a", network: true)  // the setting flipped: the Net variant of slot 1
        await s.release(an)
        #expect(w.entries == ["1", "1n"])
        w.clear()
        let b = try await s.acquire(chatID: "b", network: false)
        #expect(b.slot == 1)
        #expect(w.entries == ["1", "1n"], "both containers the slot served for chat a are wiped before chat b runs")
        #expect(await s.holding("a") == nil)
        #expect(await s.holding("b")?.variants == [false])
        await s.release(b)
    }

    @Test func aFailedWipeNeverHandsTheSlotOn() async throws {
        let w = Wipes()
        let s = FileToolsSlots(capacity: 1, wiper: w.wiper)
        let a = try await s.acquire(chatID: "a", network: false)
        await s.release(a)
        w.fail.withLock { _ = $0.insert(1) }
        await #expect(throws: FileToolsSlots.SlotError.self) { _ = try await s.acquire(chatID: "b", network: false) }
        #expect(w.entries.suffix(2) == ["1", "1"], "one retry, then refused")
        #expect(await s.holding("b") == nil)
        // Chat a's slot is not given back unverified either: its next call wipes again.
        w.fail.withLock { $0.removeAll() }
        w.clear()
        let a2 = try await s.acquire(chatID: "a", network: false)
        #expect(w.entries == ["1"])
        await s.release(a2)
    }

    @Test func beyondTheCapacityAChatWaitsAndIsListedAsWaiting() async throws {
        let w = Wipes()
        let s = FileToolsSlots(capacity: 1, wiper: w.wiper)
        let a = try await s.acquire(chatID: "a", network: false)
        let waiter = Task { try await s.acquire(chatID: "b", network: false, waitKey: "call-b") }
        for _ in 0..<200 where !FileToolsSlots.isWaiting("call-b") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(FileToolsSlots.isWaiting("call-b"))
        #expect(await s.snapshot().map(\.holder) == ["a"])
        w.clear()
        await s.release(a)
        let b = try await waiter.value
        #expect(b.slot == 1)
        #expect(!FileToolsSlots.isWaiting("call-b"))
        #expect(w.entries == ["1"], "the slot was wiped before the waiting chat got it")
        await s.release(b)
    }

    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let s = FileToolsSlots(capacity: 1, wiper: Wipes().wiper)
        let a = try await s.acquire(chatID: "a", network: false)
        let waiter = Task { try await s.acquire(chatID: "b", network: false, waitKey: "call-x") }
        for _ in 0..<200 where !FileToolsSlots.isWaiting("call-x") { try await Task.sleep(for: .milliseconds(5)) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        #expect(!FileToolsSlots.isWaiting("call-x"))
        await s.release(a)
        #expect(await s.snapshot().map(\.busy) == [0])
    }

    @Test func aNewChatTakesAFreshSlotFirstThenTheLeastRecentlyUsed() async throws {
        let s = FileToolsSlots(capacity: 2, wiper: Wipes().wiper)
        let a = try await s.acquire(chatID: "a", network: false); await s.release(a)
        let b = try await s.acquire(chatID: "b", network: false); await s.release(b)
        #expect(a.slot != b.slot, "a never-used slot first")
        let a2 = try await s.acquire(chatID: "a", network: false); await s.release(a2)  // b's slot is now the older
        let c = try await s.acquire(chatID: "c", network: false)
        #expect(c.slot == b.slot)
        await s.release(c)
        await s.forget("a")
        #expect(await s.holding("a") == nil)
    }
}
