// AT-206 part 1 (R-206 AC1; M2.T12 step 2): the scheduler tracks each model's resident bytes, keeps the total ≤ B and
// evicts idle models in exactly the E.2.7 order (image/video → reranker/embeddings → second chat variant → TTS → STT
// → active chat), LRU within a rank; an active lease is never evicted; max(measured, catalog) is the figure.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct FitOrEvictTests {
    @Test func evictionOrderIsExactlyE27() async throws {
        let clock = ManualClock()
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: clock.fn)
        await s.setPolicy(Synth.policy(10))
        // Resident, each released (idle), oldest first within a rank where it matters.
        let order: [(String, Double, ResidencyRole)] = [
            ("chat-a", 2, .chat), ("stt", 1, .stt), ("tts", 1, .tts), ("embed", 1, .embed), ("rerank", 1, .rerank), ("img", 1, .image),
            ("chat-b", 2, .chat),  // newest chat: chat-a becomes the second variant
        ]
        for (k, gb, role) in order {
            clock.advance(1)
            let t = try await s.ensureLoaded(role: role, model: Synth.slot(k, gb))
            await s.release(t)
        }
        #expect(await s.usedBytes == UInt64(9 * Synth.GB))
        // An 8 GB load forces out everything but the newest chat (2 GB), in E.2.7 order; a 9 GB one takes it too.
        let v = try await s.ensureLoaded(role: .video, model: Synth.slot("vid", 8))
        var evicted = loader.events.filter { $0.hasPrefix("unload") }.map { String($0.dropFirst(7)) }
        #expect(evicted == ["img", "embed", "rerank", "chat-a", "tts", "stt"])
        await s.release(v)
        _ = try await s.ensureLoaded(role: .video, model: Synth.slot("vid-big", 9.5))
        evicted = loader.events.filter { $0.hasPrefix("unload") }.map { String($0.dropFirst(7)) }
        #expect(evicted.suffix(2) == ["vid", "chat-b"], "an idle job model goes before the active chat")
    }

    @Test func activeLeaseIsNeverEvicted() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(8))
        let chat = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat", 6))  // streaming: lease held
        await #expect(throws: (any Error).self) { _ = try await s.ensureLoaded(role: .image, model: Synth.slot("img", 4)) }
        #expect(loader.loaded == ["chat"])
        await s.release(chat)
        _ = try await s.ensureLoaded(role: .image, model: Synth.slot("img", 4))
        #expect(loader.loaded == ["img"])
    }

    @Test func allowOverBudgetLoadsAfterEvictingTheIdle() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(8, allowOver: true))
        let e = try await s.ensureLoaded(role: .embed, model: Synth.slot("embed", 1)); await s.release(e)
        _ = try await s.ensureLoaded(role: .chat, model: Synth.slot("big", 20))
        #expect(loader.loaded == ["big"])
        #expect(await s.log.contains("overBudget big"))
    }

    /// M7 bars (T1 search latency): the MLX embedding model is a service model, not the MLX chat container — with the
    /// default capacity (one MLX container) and B = 9.5 GB it stays beside the T1 chat model instead of replacing it;
    /// the budget still applies (embed goes first when B needs room).
    @Test func theEmbeddingModelDoesNotTakeTheMLXChatContainer() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)  // default capacity: one per engine
        await s.setPolicy(Synth.policy(9.5))
        let chat = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b", 6.5)); await s.release(chat)
        let e = try await s.ensureLoaded(role: .embed, model: Synth.slot("embed", 1.2)); await s.release(e)
        #expect(Set(loader.loaded) == ["chat-9b", "embed"])
        let again = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b", 6.5)); await s.release(again)
        #expect(Set(loader.loaded) == ["chat-9b", "embed"], "no reload")
        // over B: the embed model (lower E.2.7 rank) goes, not the chat model
        _ = try await s.ensureLoaded(role: .rerank, model: Synth.slot("rerank", 2.5))
        #expect(loader.loaded.contains("chat-9b") && !loader.loaded.contains("embed"))
        #expect(EvictionPolicy.capacityKind(Synth.slot("embed", 1)) == nil && EvictionPolicy.capacityKind(Synth.slot("chat", 1)) == .mlx)
    }

    @Test func measuredAboveCatalogCountsAndEngineCapacityReplaces() async throws {
        let loader = FakeLoader()
        loader.measured["chat-mlx"] = UInt64(5 * Synth.GB)  // engine reports more than the catalog said
        let s = ModelScheduler(loader: loader, clock: ManualClock().fn)  // default capacity: one per engine
        await s.setPolicy(Synth.policy(9.5))
        let a = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-mlx", 3)); await s.release(a)
        #expect(await s.usedBytes == UInt64(5 * Synth.GB))
        // Evil on llama.cpp co-resides when it fits (4 + 5 ≤ 9.5) …
        let b = try await s.ensureLoaded(role: .chat, model: Synth.slot("evil-gguf", 4, .llama)); await s.release(b)
        #expect(Set(loader.loaded) == ["chat-mlx", "evil-gguf"])
        // … a second MLX model replaces the first (one MLX container).
        _ = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-mlx-2", 2))
        #expect(Set(loader.loaded) == ["evil-gguf", "chat-mlx-2"])
    }

    @Test func doesNotFitThrowsNotEnoughMemory() async throws {
        let s = ModelScheduler(loader: FakeLoader(), clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(4))
        do {
            _ = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b", 6.5))
            Issue.record("expected notEnoughMemory")
        } catch let e as AntiChatError {
            #expect(e.userMessageKey == "model.notEnoughMemory")
        }
    }
}
