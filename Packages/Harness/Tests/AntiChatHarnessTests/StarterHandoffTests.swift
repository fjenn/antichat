// AT-203 (R-203 AC2–AC4) unit legs — M2.T20: the starter answers while the tier model downloads; the switch happens only
// at a turn boundary (a reply streaming at the moment of verification keeps its slot); `starter.upgraded` once; a tier
// model that does not fit (memory, NFR-R5) keeps the chat on the starter with `model.usingLighter`.
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite struct StarterHandoffTests {
    final class Fake: ModelReadinessProviding, @unchecked Sendable {
        let tier = Mutex(false)
        let percent = Mutex(37)
        func starterSlot() -> ModelSlot? { ModelSlot(engine: .mlx, key: "chat-0.8b", path: "/m/installs/chat-0.8b") }
        func tierSlot() -> ModelSlot? { tier.withLock { $0 } ? ModelSlot(engine: .mlx, key: "chat-2b", path: "/m/installs/chat-2b") : nil }
        func tierPercent() -> Int? { percent.withLock { $0 } }
    }

    final class Flag: @unchecked Sendable {
        let v = Mutex(true)
        var value: Bool { get { v.withLock { $0 } } set { v.withLock { $0 = newValue } } }
    }

    static let dev = ModelSlot(engine: .mlx, key: "dev", path: "/dev")

    @Test func starterUntilTierVerifiedThenNextTurn() {
        let r = Fake(), idle = Flag()
        let h = StarterHandoff(readiness: r, isIdle: { idle.value }, fallback: { Self.dev })
        #expect(h.slot().key == "chat-0.8b")
        #expect(h.phase == .starter(percent: 37))
        #expect(StarterLabelModel.label(phase: h.phase, upgradeNotice: false) == .quick(percent: 37))
        // A reply is streaming when the tier model is verified: every slot() of that turn stays on the starter.
        idle.value = false
        r.tier.withLock { $0 = true }
        for _ in 0..<5 { #expect(h.slot().key == "chat-0.8b") }
        // Next turn boundary: the tier model.
        idle.value = true
        #expect(h.slot().key == "chat-2b")
        #expect(h.phase == .tier)
        #expect(h.consumeUpgradeNotice())
        #expect(!h.consumeUpgradeNotice())  // shown once
        #expect(StarterLabelModel.label(phase: h.phase, upgradeNotice: false) == .none)
    }

    @Test func tierModelThatDoesNotFitStaysOnStarter() {
        let r = Fake()
        r.tier.withLock { $0 = true }
        let h = StarterHandoff(readiness: r, isIdle: { true }, fits: { $0.key != "chat-2b" }, fallback: { Self.dev })
        #expect(h.slot().key == "chat-0.8b")
        #expect(h.phase == .lighter)
        #expect(StarterLabelModel.label(phase: h.phase, upgradeNotice: false).copyKey == "model.usingLighter")
        #expect(!h.consumeUpgradeNotice())
    }

    @Test func memoryRefusedAtLoadFallsBackToStarter() {
        let r = Fake()
        r.tier.withLock { $0 = true }
        let h = StarterHandoff(readiness: r, isIdle: { true }, fallback: { Self.dev })
        #expect(h.slot().key == "chat-2b")
        h.tierLoadRefused(key: "chat-2b")
        #expect(h.slot().key == "chat-0.8b")
        #expect(h.phase == .lighter)
    }

    @Test func nothingInstalledUsesFallbackAndFlagOffWaitsForTier() {
        final class None: ModelReadinessProviding {
            func starterSlot() -> ModelSlot? { nil }
            func tierSlot() -> ModelSlot? { nil }
            func tierPercent() -> Int? { nil }
        }
        #expect(StarterHandoff(readiness: None(), isIdle: { true }, fallback: { Self.dev }).slot().key == "dev")
        // FeatureFlag.starterHandoff off: the starter is never used.
        #expect(StarterHandoff(readiness: Fake(), enabled: false, isIdle: { true }, fallback: { Self.dev }).slot().key == "dev")
    }
}
