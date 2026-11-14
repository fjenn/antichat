// M1.T15 AT-007 (unit leg, R-007 AC3/AC4 harness half): ThinkHarderPolicy maps the toggle per family — the thinking
// flag for Qwen3.5/3.6 and Gemma 4, the sampling-only preset (temperature −0.2, larger budget, no prompt clause) for a
// model without a thinking mode — and TurnController applies it to the request; the reasoning duration lands in
// provenance (`reasoning_ms`) and the TurnResult; `chat.think_harder` is stored per chat.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite("ThinkHarderPolicyTests") struct ThinkHarderPolicyTests {
    static let base = Sampling(temperature: 0.6, topP: 0.95, maxTokens: 1024)

    static func slot(_ key: String, _ path: String = "/models/x") -> ModelSlot { ModelSlot(engine: .mlx, key: key, path: path) }

    @Test func familiesWithThinkingMode() {
        for key in ["chat-0.8b", "chat-2b", "chat-9b-q4", "evil-9b", "chat-35b-q4", "chat-g26"] {
            #expect(ThinkHarderPolicy.family(of: Self.slot(key)).hasThinkingMode, "\(key)")
            let r = ThinkHarderPolicy.apply(true, slot: Self.slot(key), capabilities: nil, sampling: Self.base)
            #expect(r.mode == .reasoning)
            #expect(r.reasoning.on)
            #expect(r.sampling.temperature == Self.base.temperature)
            #expect(r.sampling.maxTokens == Self.base.maxTokens + ThinkHarderPolicy.reasoningBudget)
        }
        #expect(ThinkHarderPolicy.family(of: Self.slot("x", "/m/mlx-community/Qwen3.6-27B")) == .qwen36)
        #expect(ThinkHarderPolicy.family(of: Self.slot("x", "/m/gemma-4-e4b-it")) == .gemma4)
    }

    @Test func offLeavesTheRequestUnchanged() {
        let r = ThinkHarderPolicy.apply(false, slot: Self.slot("chat-9b-q4"), capabilities: nil, sampling: Self.base)
        #expect(r.mode == .off)
        #expect(r.reasoning == .off)
        #expect(r.sampling == Self.base)
    }

    @Test func presetForAModelWithoutThinkingMode() {
        // Unknown family, or the engine says reasoning=false (no-reasoning.jsonl caps).
        let noCaps = EngineCapabilities(engines: [.scripted], reasoning: false)
        for (slot, caps) in [(Self.slot("llama-3-8b", "/m/llama"), nil), (ModelSlot.scripted("s"), noCaps),
                             (Self.slot("chat-9b-q4"), noCaps)] as [(ModelSlot, EngineCapabilities?)] {
            let r = ThinkHarderPolicy.apply(true, slot: slot, capabilities: caps, sampling: Self.base)
            #expect(r.mode == .preset)
            #expect(!r.reasoning.on)
            #expect(abs(r.sampling.temperature - 0.4) < 1e-6)
            #expect(r.sampling.maxTokens == Self.base.maxTokens + ThinkHarderPolicy.reasoningBudget)
            #expect(r.sampling.topP == Self.base.topP)
            #expect(ThinkHarderPolicy.tooltipKey(slot: slot, capabilities: caps) == "think.tip.preset")
        }
        #expect(ThinkHarderPolicy.tooltipKey(slot: Self.slot("chat-9b-q4"), capabilities: nil) == "tip.think")
        // Temperature never goes below 0.
        let cold = ThinkHarderPolicy.apply(true, slot: Self.slot("other"), capabilities: nil,
                                           sampling: Sampling(temperature: 0.1))
        #expect(cold.sampling.temperature == 0)
    }

    @Test func turnControllerAppliesTheToggleAndAddsNoPromptClause() async throws {
        // Reasoning-capable scripted engine (default caps).
        let h = try Harness(script: #"{"t":"textDelta","v":"ok","delayMs":1}"#)
        var (_, a) = await h.send("first")
        _ = try await h.log.waitFinished(a)
        let off = try #require(await h.controller.lastRequest)
        #expect(!off.reasoning.on)
        await h.controller.setThinkHarder(true)
        (_, a) = await h.send("second", parent: a)
        _ = try await h.log.waitFinished(a)
        let on = try #require(await h.controller.lastRequest)
        #expect(on.reasoning.on)
        #expect(await h.controller.lastThinkHarderMode == .reasoning)
        #expect(on.sampling.maxTokens == off.sampling.maxTokens + ThinkHarderPolicy.reasoningBudget)
        // Same system prompt bytes either way (no "think step by step" clause; the cached prefix survives).
        #expect(on.flattenedMessages.first?.role == .system)
        #expect(on.flattenedMessages.first?.content == off.flattenedMessages.first?.content)
        #expect(!on.flattenedMessages.contains { $0.content.lowercased().contains("step by step") })

        // No thinking mode: the preset (reasoning stays off, temperature −0.2).
        let p = try Harness(script: """
            {"t":"caps","reasoning":false}
            {"t":"textDelta","v":"ok","delayMs":1}
            """)
        await p.controller.setThinkHarder(true)
        let (_, b) = await p.send("hi")
        _ = try await p.log.waitFinished(b)
        let preset = try #require(await p.controller.lastRequest)
        #expect(await p.controller.lastThinkHarderMode == .preset)
        #expect(!preset.reasoning.on)
        #expect(abs(preset.sampling.temperature - (Sampling().temperature - 0.2)) < 1e-6)
    }

    @Test func reasoningDurationIsRecorded() async throws {
        // 20 reasoning deltas, then the answer. The controller's event clock is injected: every engine event is
        // stamped 50 ms after the previous one, so the span first reasoning delta → first answer delta is exactly
        // 20 × 50 ms = 1.000 s whatever the host load (wall-clock bounds failed under load avg > 100).
        let tick = TestTicker(step: .milliseconds(50))
        let h = try Harness(script: """
            {"t":"reasoningDelta","v":" hm","delayMs":1,"repeat":20}
            {"t":"textDelta","v":"Done.","delayMs":1}
            """, now: { tick.next() })
        await h.controller.setThinkHarder(true)
        let (_, a) = await h.send("think")
        let r = try await h.log.waitFinished(a)
        let secs = try #require(r.reasoningSeconds)
        #expect(abs(secs - 1.0) < 1e-9, "\(secs)")
        let stored = try #require(try h.message(a)?.provenance?.reasoningMs)
        #expect(abs(stored / 1000 - secs) < 0.01)
        // No reasoning → no duration.
        let n = try Harness(script: #"{"t":"textDelta","v":"ok","delayMs":1}"#)
        let (_, b) = await n.send("plain")
        #expect(try await n.log.waitFinished(b).reasoningSeconds == nil)
    }

    @Test func thinkHarderIsStoredPerChat() throws {
        let db = try AppDatabase.inMemory()
        let repo = ChatRepository(db)
        let a = try repo.create(title: "A")
        let b = try repo.create(title: "B")
        #expect(try !repo.thinkHarder(a.id))  // new chats default off
        let before = try #require(try repo.chat(a.id)).updatedAt
        #expect(try repo.setThinkHarder(a.id, true))
        #expect(try repo.thinkHarder(a.id))
        #expect(try !repo.thinkHarder(b.id))
        #expect(try #require(try repo.chat(a.id)).updatedAt == before)  // not an edit: sidebar order kept
        #expect(try !repo.setThinkHarder("missing", true))
        #expect(Migrations.identifiers.firstIndex(of: "v2_think_harder") == 1)  // after v1_core (M1.T16 appends v3_tool_permission)
    }
}

/// A deterministic clock: each call returns the previous instant + `step`.
final class TestTicker: Sendable {
    private let state: Mutex<ContinuousClock.Instant>
    private let step: Duration
    init(step: Duration) {
        self.step = step
        state = Mutex(.now)
    }
    func next() -> ContinuousClock.Instant {
        state.withLock { $0 = $0.advanced(by: step); return $0 }
    }
}
