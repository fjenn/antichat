//
//  MetalGateTests.swift
//  osaurus
//
//  MetalGate is mutual exclusion keyed by producer identity: same-model
//  generations share the lock (so batching is preserved); a different model, an
//  embedder, and a model load are each exclusive. These tests exercise the
//  basic acquire/release balance for those roles.
//

import Foundation
import Testing

// ANTICHAT-PATCH: UP-OS-034 ported test imports the OsaurusVendored target
@testable import OsaurusVendored
// ANTICHAT-PATCH-END

/// Ordered, actor-isolated event log used to prove exclusion deterministically:
/// a blocked waiter cannot record its "acquired" event until the current holder
/// records its "released" event first.
private actor GateOrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@Suite(.serialized)
struct MetalGateTests {

    @Test func embeddingProceedsWhenIdle() async throws {
        let gate = MetalGate.makeForTesting()
        try await gate.enterEmbedding()
        await gate.exitEmbedding()
    }

    @Test func embeddingsSerializeWithoutDeadlock() async throws {
        let gate = MetalGate.makeForTesting()
        // Embedding is now EXCLUSIVE (not a reentrant counter), so a single task
        // cannot hold two embedding acquisitions at once — acquire and release
        // each in turn. (Acquiring twice without releasing would self-deadlock,
        // which is the correct exclusion behavior.)
        try await gate.enterEmbedding()
        await gate.exitEmbedding()
        try await gate.enterEmbedding()
        await gate.exitEmbedding()
    }

    @Test func sameModelGenerationsShareTheLock() async throws {
        let gate = MetalGate.makeForTesting()
        // Same-model generations are shared — two acquisitions coexist
        // (batching), and both release cleanly.
        try await gate.enterGeneration(model: "qwen3.5-4b")
        try await gate.enterGeneration(model: "qwen3.5-4b")
        await gate.exitGeneration(model: "qwen3.5-4b")
        await gate.exitGeneration(model: "qwen3.5-4b")
    }

    @Test func modelLoadProceedsWhenIdle() async {
        let gate = MetalGate.makeForTesting()
        // A model load is an exclusive producer; it acquires and releases
        // cleanly when nothing else holds the GPU.
        await gate.enterModelLoad(model: "qwen3.5-4b")
        await gate.exitModelLoad(model: "qwen3.5-4b")
    }

    // MARK: - Model teardown (unload) owner — exclusive against every producer

    @Test func modelTeardownProceedsWhenIdle() async {
        let gate = MetalGate.makeForTesting()
        // Unload teardown is exclusive; it acquires and releases cleanly when
        // nothing else holds the GPU.
        await gate.enterModelTeardown(model: "qwen3.5-4b")
        await gate.exitModelTeardown(model: "qwen3.5-4b")
    }

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    @Test func teardownWaitsForModelLoadToRelease() async {
        let gate = MetalGate.makeForTesting()
        // A teardown must not overlap a model load on the shared device.
        let rec = GateOrderRecorder()
        await gate.enterModelLoad(model: "incoming-model")
        let waiter = Task {
            await gate.enterModelTeardown(model: "outgoing-model")
            await rec.record("teardown-acquired")
            await gate.exitModelTeardown(model: "outgoing-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("load-released")
        await gate.exitModelLoad(model: "incoming-model")
        _ = await waiter.value
        let events = await rec.events
        #expect(events == ["load-released", "teardown-acquired"])
    }

    @Test func generationWaitsForTeardownToRelease() async throws {
        let gate = MetalGate.makeForTesting()
        // The restore side: a chat-model reload's generation must not start
        // while a previous model's teardown is still draining the device.
        let rec = GateOrderRecorder()
        await gate.enterModelTeardown(model: "old-model")
        let waiter = Task {
            try await gate.enterGeneration(model: "new-model")
            await rec.record("gen-acquired")
            await gate.exitGeneration(model: "new-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("teardown-released")
        await gate.exitModelTeardown(model: "old-model")
        _ = try await waiter.value
        let events = await rec.events
        #expect(events == ["teardown-released", "gen-acquired"])
    }

    // MARK: - Media prep owner — exclusive against every producer

    @Test func mediaPrepProceedsWhenIdle() async throws {
        let gate = MetalGate.makeForTesting()
        try await gate.enterMediaPrep(model: "omni-model")
        await gate.exitMediaPrep(model: "omni-model")
    }

    @Test func mediaPrepWaitsForSameModelGenerationToRelease() async throws {
        let gate = MetalGate.makeForTesting()
        // The prepareInput hole: a media request's submit-thread encode evals
        // must not overlap an in-flight decode even for the SAME model — the
        // shared gen owner would have admitted it. Prove the exclusive prep
        // owner waits for the generation to release.
        let rec = GateOrderRecorder()
        try await gate.enterGeneration(model: "omni-model")
        let waiter = Task {
            try await gate.enterMediaPrep(model: "omni-model")
            await rec.record("prep-acquired")
            await gate.exitMediaPrep(model: "omni-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("gen-released")
        await gate.exitGeneration(model: "omni-model")
        _ = try await waiter.value
        let events = await rec.events
        #expect(events == ["gen-released", "prep-acquired"])
    }

    @Test func mediaPrepsAreMutuallyExclusive() async throws {
        let gate = MetalGate.makeForTesting()
        // Two media requests' prep evals must not encode concurrently either
        // (prep-vs-prep on two submit threads).
        let rec = GateOrderRecorder()
        try await gate.enterMediaPrep(model: "omni-model")
        let waiter = Task {
            try await gate.enterMediaPrep(model: "omni-model")
            await rec.record("second-prep-acquired")
            await gate.exitMediaPrep(model: "omni-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("first-prep-released")
        await gate.exitMediaPrep(model: "omni-model")
        _ = try await waiter.value
        let events = await rec.events
        #expect(events == ["first-prep-released", "second-prep-acquired"])
    }

    // MARK: - Source contract: media prep is actually gate-bracketed

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // MARK: - PII detection (Rampart) owner — exclusive against every producer

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // MARK: - Cancellation-aware waits (Stop must not park behind a wedged holder)

    @Test func cancelledWaiterThrowsAndLeavesGateConsistent() async throws {
        let gate = MetalGate.makeForTesting()
        // A generation waiting behind an exclusive holder is cancelled (Stop).
        // It must throw CancellationError promptly — without waiting for the
        // holder — and must NOT have acquired, so the gate stays balanced.
        // ANTICHAT-PATCH: UP-OS-017 exclusive holder: embedding instead of the stripped PII lane
        try await gate.enterEmbedding()
        // ANTICHAT-PATCH-END
        let waiter = Task { () -> Bool in
            do {
                try await gate.enterGeneration(model: "stopped-model")
                // Wrongly admitted: balance and fail below.
                await gate.exitGeneration(model: "stopped-model")
                return false
            } catch {
                return error is CancellationError
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
        waiter.cancel()
        let threwCancellation = await waiter.value
        #expect(threwCancellation, "cancelled gate waiter did not throw CancellationError")

        // Holder still works and the gate drains cleanly afterwards.
        // ANTICHAT-PATCH: UP-OS-017 exclusive holder: embedding instead of the stripped PII lane
        await gate.exitEmbedding()
        // ANTICHAT-PATCH-END
        try await gate.enterGeneration(model: "next-model")
        await gate.exitGeneration(model: "next-model")
    }

    @Test func cancelledWaiterUnblocksSameOwnerAdmissions() async throws {
        let gate = MetalGate.makeForTesting()
        // A parked foreign waiter blocks new same-owner shared admissions
        // (anti-starvation). When that waiter is cancelled it must re-wake the
        // others so a shared acquisition parked behind it gets admitted.
        try await gate.enterGeneration(model: "modelA")
        let foreign = Task { () -> Bool in
            do {
                try await gate.enterEmbedding()
                await gate.exitEmbedding()
                return false
            } catch {
                return error is CancellationError
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
        // Same-owner shared admission is blocked by the parked embedder.
        let sameOwner = Task {
            try await gate.enterGeneration(model: "modelA")
            await gate.exitGeneration(model: "modelA")
        }
        try? await Task.sleep(for: .milliseconds(80))
        foreign.cancel()
        let foreignCancelled = await foreign.value
        #expect(foreignCancelled)
        // With the foreign waiter gone, the shared admission must proceed
        // while modelA still holds the gate.
        _ = try await sameOwner.value
        await gate.exitGeneration(model: "modelA")
    }

    @Test func alreadyCancelledAcquireThrowsImmediately() async {
        let gate = MetalGate.makeForTesting()
        let task = Task { () -> Bool in
            // Establish cancellation before admission. Cancelling from the
            // parent races with this task completing on the idle gate.
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            do {
                try await gate.enterGeneration(model: "never-ran")
                await gate.exitGeneration(model: "never-ran")
                return false
            } catch {
                return error is CancellationError
            }
        }
        let threwCancellation = await task.value
        #expect(threwCancellation)
    }

    // MARK: - Source contract: the Rampart detector is actually gate-bracketed

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // MARK: - Source contract: gate-holding code never awaits the PII owner

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END

    // MARK: - Source contract: the unload teardown is actually gate-bracketed

    // ANTICHAT-PATCH: UP-OS-017 ported test: drop tests of the stripped PII/image lanes (UP-OS-017) and tests that read non-vendored Osaurus sources
    // ANTICHAT-PATCH-END
}
