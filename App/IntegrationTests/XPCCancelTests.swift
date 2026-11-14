// M1.T05 gate: `make test-integration-stub FILTER=XPCCancelTests` — Cancel{requestID} → done(cancelled)
// ≤ 300 ms p95 over 50 runs (NFR-U6, architecture §4.3), measured app-side from sending Cancel to the arrival of
// the terminal batch, through the real helper.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class XPCCancelTests: XCTestCase {
    static func p(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded(.up)))]
    }

    /// Starts a request, waits for the first content batch (or `afterMs` when none is expected), cancels, and
    /// returns (latency, terminal event).
    static func cancelOnce(_ client: EngineClient, _ slot: ModelSlot, waitForContent: Bool, afterMs: Int = 0) async throws -> (Double, EngineEvent?) {
        let req = EngineTestSupport.ask(slot)
        let stream = client.chatBatches(req)
        var cancelledAt: ContinuousClock.Instant?
        var latency = -1.0
        var terminal: EngineEvent?
        if !waitForContent {
            Task {
                try? await Task.sleep(for: .milliseconds(afterMs))
                client.cancel(req.requestID)
            }
            cancelledAt = .now + .milliseconds(afterMs)
        }
        for await b in stream {
            if waitForContent, cancelledAt == nil, b.tokens > 0 {
                cancelledAt = .now
                client.cancel(req.requestID)
            }
            if let t = b.events.first(where: \.isTerminal) {
                terminal = t
                if let c = cancelledAt { latency = EngineTestSupport.secs(b.receivedAt - c) * 1000 }
            }
        }
        return (latency, terminal)
    }

    func testCancelMidStreamP95Under300ms() async throws {
        let client = EngineClient(appBuild: "it-cancel")
        defer { client.disconnect() }
        try await client.ensureConnected()
        let slot = try EngineTestSupport.longStream()
        var ms: [Double] = []
        for i in 0..<50 {
            let (l, t) = try await Self.cancelOnce(client, slot, waitForContent: true)
            XCTAssertEqual(t, .done(.cancelled), "run \(i)")
            XCTAssertGreaterThanOrEqual(l, 0, "run \(i)")
            ms.append(l)
        }
        let p50 = Self.p(ms, 0.5), p95 = Self.p(ms, 0.95)
        EngineTestSupport.evidence("xpc-cancel-midstream", ["runs": ms.count, "p50_ms": p50, "p95_ms": p95, "max_ms": ms.max() ?? -1, "ms": ms])
        XCTAssertLessThanOrEqual(p95, 300, "cancel → done(cancelled) p95 \(p95) ms")
    }

    func testCancelMidStreamOnTinyMLXP95Under300ms() async throws {
        // Real MLX generation in the helper (tiny-mlx-llm stub model; skipped without ANTICHAT_FIXTURES). The no-EOS
        // variant always runs to maxTokens (M1.T13: the plain model ended a run before Stop now and then), so each
        // cancel lands mid-stream; the bar stays done(cancelled) on every run and p95 ≤ 300 ms.
        guard let tiny = EngineTestSupport.tinyMLXNoEOS else { throw XCTSkip("tiny-mlx-llm not available (ANTICHAT_FIXTURES)") }
        let client = EngineClient(appBuild: "it-cancel-mlx")
        defer { client.disconnect() }
        try await client.ensureConnected()
        let warmErr = await client.warmup(tiny)
        XCTAssertNil(warmErr)
        // Determinism check: without Stop the variant always ends by length, never by an end-of-sequence token.
        for seed in 0..<5 {
            let req = ChatRequest(modelSlot: tiny, messages: [ChatMessage(role: .user, content: "Tell me a long story")],
                                  sampling: Sampling(temperature: 0.8, maxTokens: 300, seed: UInt64(seed)))
            let ev = try await EngineTestSupport.drain(client.chatBatches(req)).flatMap(\.events)
            XCTAssertEqual(ev.last, .done(.length), "seed \(seed)")
        }
        var ms: [Double] = []
        for i in 0..<50 {
            let req = ChatRequest(modelSlot: tiny, messages: [ChatMessage(role: .user, content: "Tell me a long story")],
                                  sampling: Sampling(temperature: 0.8, maxTokens: 4000, seed: UInt64(i)))
            var cancelledAt: ContinuousClock.Instant?
            var latency = -1.0
            var terminal: EngineEvent?
            for await b in client.chatBatches(req) {
                if cancelledAt == nil, b.tokens > 0 {
                    cancelledAt = .now
                    client.cancel(req.requestID)
                }
                if let t = b.events.first(where: \.isTerminal) {
                    terminal = t
                    if let c = cancelledAt { latency = EngineTestSupport.secs(b.receivedAt - c) * 1000 }
                }
            }
            XCTAssertEqual(terminal, .done(.cancelled), "run \(i)")
            XCTAssertGreaterThanOrEqual(latency, 0, "run \(i): Stop was sent before the terminal")
            ms.append(latency)
        }
        let p95 = Self.p(ms, 0.95)
        EngineTestSupport.evidence("xpc-cancel-midstream-tiny-mlx", ["runs": ms.count, "p50_ms": Self.p(ms, 0.5), "p95_ms": p95, "max_ms": ms.max() ?? -1, "ms": ms])
        XCTAssertLessThanOrEqual(p95, 300)
    }

    func testCancelDuringAModelLoadStillAnswersIn300ms() async throws {
        // The helper is busy loading (a 3 s scripted load): the router's grace answers for the stuck request.
        let client = EngineClient(appBuild: "it-cancel-load")
        defer { client.disconnect() }
        try await client.ensureConnected()
        var ms: [Double] = []
        for i in 0..<5 {
            let slot = try EngineTestSupport.script([#"{"t":"load","ms":3000,"steps":3}"#, #"{"t":"textDelta","v":"x"}"#], name: "load\(i)")
            let (l, t) = try await Self.cancelOnce(client, slot, waitForContent: false, afterMs: 200)
            XCTAssertEqual(t, .done(.cancelled), "run \(i)")
            ms.append(l)
        }
        EngineTestSupport.evidence("xpc-cancel-during-load", ["runs": ms.count, "max_ms": ms.max() ?? -1, "ms": ms])
        XCTAssertLessThanOrEqual(ms.max() ?? 999, 300)
    }

    func testStopRightAfterTheHandshakeIsNeverLost() async throws {
        // Flake investigation 2026-11-04: a Stop sent just as the lazy connection (or the reconnect after a helper
        // restart) finished could reach the helper before its request, which the router then ran to the end. The
        // canceller here spins until the handshake lands and cancels at once, i.e. inside that window. Each 15 s
        // stream must still end done(cancelled) within 3 s.
        let slot = try EngineTestSupport.longStream()
        for i in 0..<20 {
            let client = EngineClient(appBuild: "it-cancel-handshake")
            let req = EngineTestSupport.ask(slot)
            let started = ContinuousClock.now
            let stream = client.chatBatches(req)
            let canceller = Task.detached {
                while client.lastAck == nil, ContinuousClock.now - started < .seconds(10) { await Task.yield() }
                client.cancel(req.requestID)
            }
            let events = try await EngineTestSupport.drain(stream, timeout: .seconds(20)).flatMap(\.events)
            await canceller.value
            let took = ContinuousClock.now - started
            XCTAssertEqual(events.filter(\.isTerminal), [.done(.cancelled)], "run \(i)")
            XCTAssertLessThan(took, .seconds(3), "run \(i): Stop was lost (\(took))")
            client.disconnect()
        }
    }

    func testRequestStillCancellableBeforeTheLazyConnection() async throws {
        // Cancel before the handshake finished: the request is dropped client-side and still ends once.
        let client = EngineClient(appBuild: "it-cancel-early")
        defer { client.disconnect() }
        let slot = try EngineTestSupport.longStream()
        let req = EngineTestSupport.ask(slot)
        let stream = client.chatBatches(req)
        client.cancel(req.requestID)
        let events = try await EngineTestSupport.drain(stream).flatMap(\.events)
        XCTAssertEqual(events.filter(\.isTerminal), [.done(.cancelled)])
    }
}
