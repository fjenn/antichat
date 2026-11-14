// M1.T18 AT-009 leg (3) harness half (R-009 AC3): a prompt larger than the window minus the reserved output is
// refused before any ChatRequest exists.
//   make test-unit FILTER=OversizeGuardTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("OversizeGuardTests") struct OversizeGuardTests {
    @Test func limitIsWindowMinusReservedOutput() {
        #expect(OversizeGuard.limit(window: 4096, reservedOutput: 1024) == 3072)
        // ≈ chars / 4: 12,000 ASCII chars ≈ 3,000 tokens (+ overhead) fit; 13,000 do not.
        #expect(OversizeGuard.check(text: String(repeating: "a", count: 12_000), window: 4096, reservedOutput: 1024) == nil)
        let e = OversizeGuard.check(text: String(repeating: "a", count: 13_000), window: 4096, reservedOutput: 1024)
        #expect(e?.fullCode == "context.tooLarge")
        #expect(e?.userMessageKey == "ctx.tooLarge")
    }

    @Test func pasteCardsCount() {
        let card = String(repeating: "b", count: 8_000)
        #expect(OversizeGuard.check(text: "hi", pastedTexts: [card], window: 4096, reservedOutput: 1024) == nil)
        #expect(OversizeGuard.check(text: "hi", pastedTexts: [card, card], window: 4096, reservedOutput: 1024) != nil)
    }

    @Test func policyUsesTheFakeWindow() {
        let slot = ModelSlot.scripted("x")
        let policy = ContextPolicy(windowOverride: 4096)
        #expect(OversizeGuard.check(text: String(repeating: "c", count: 20_000), slot: slot, policy: policy) != nil)
        #expect(OversizeGuard.check(text: String(repeating: "c", count: 20_000), slot: slot, policy: .standard) == nil)
    }

    /// The controller refuses it too (defence in depth behind the composer): no rows, no request.
    @Test func controllerSendsNoRequest() async throws {
        let db = try AppDatabase.inMemory()
        let engine = CompactionTestEngine()
        let chatID = StorageID.make()
        let c = TurnController(chatID: chatID, database: db, engine: engine,
                               contextPolicy: ContextPolicy(windowOverride: 4096)) { .scripted("inline") }
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: String(repeating: "word ", count: 4_000), parentID: nil),
                      assistantID: a)
        try await log.wait { l in l.all.contains { if case .rejected = $0.kind { true } else { false } } }
        #expect(engine.requests.withLock { $0.isEmpty })
        #expect(try db.read { try MessageRecord.fetchCount($0) } == 0)
        let reason = log.all.compactMap { u -> String? in if case .rejected(let r) = u.kind { r } else { nil } }.first
        #expect(reason == "context.tooLarge")
        #expect(await c.phase == .idle)
    }
}
