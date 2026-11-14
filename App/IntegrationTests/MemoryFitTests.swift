// M1.T12 AT-208 leg (3) (NFR-R5): with `-FakeHardware T0` (B = 4.0 GB) a chat slot whose catalog footprint
// exceeds B is never loaded. A lighter entry of the same slot is used when one is installed (`usingLighter`
// event → `model.usingLighter` under the reply); with none, the turn ends at once with `model.notEnoughMemory`
// + [Retry], nothing reaches the helper and its memory does not move. The catalog arithmetic is the real one
// (`MemoryFitGuard`); the installed models are ScriptedEngine slots so the test needs no weights.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class MemoryFitTests: XCTestCase {
    func rss(_ pid: Int32) -> Int {
        Int(ProcessTools.run(["/bin/ps", "-o", "rss=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func fitGuard(_ entries: [MemoryFitGuard.Entry], installed: [String: ModelSlot]) -> MemoryFitGuard {
        let options = LaunchOptions.parse(["-FakeHardware", "T0"])
        XCTAssertEqual(options.fakeHardware, .T0)
        return MemoryFitGuard(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) }),
            budgetBytes: options.fakeHardware.map(MemoryFitGuard.budget(for:)),
            resolve: { installed[$0.key] })
    }

    func testLighterEntryIsUsedWhenTheModelExceedsB() async throws {
        let big = try EngineTestSupport.script([#"{"t":"textDelta","v":"from-big"}"#], name: "big")
        let small = try EngineTestSupport.script([#"{"t":"textDelta","v":"from-small"}"#], name: "small")
        // Footprints at T0: 5.98 GB × 1.2 + KV > 4.0 GB; 0.65 GB × 1.2 + KV < 4.0 GB (chat-9b-q4 / chat-0.8b sizes).
        let g = fitGuard([
            .init(key: big.key, slot: "chat", engine: "scripted", sizeGB: 5.98, context: 16384, smaller: small.key),
            .init(key: small.key, slot: "chat", engine: "scripted", sizeGB: 0.65, context: 8192),
        ], installed: [big.key: big, small.key: small])
        let sup = EngineSupervisorClient(appBuild: "it-fit", fitGuard: g)
        defer { sup.disconnect() }
        let log = EventLog(sup.events())
        let req = EngineTestSupport.ask(big, "keep me")
        var text = ""
        var last: EngineEvent?
        for try await e in sup.chat(req) {
            if case .textDelta(let t) = e { text += t }
            last = e
        }
        XCTAssertEqual(text, "from-small")
        XCTAssertEqual(last, .done(.stop))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(log.all.contains(.usingLighter(requestID: req.requestID, from: big.key, to: small.key)), "\(log.all)")
        XCTAssertEqual(AntiChatError(.modelUsingLighter).userMessageKey, "model.usingLighter")
        EngineTestSupport.evidence("AT-208-memory-fit-lighter", [
            "B_bytes": Int(MemoryFitGuard.budget(for: .T0)), "requested": big.key, "used": small.key,
            "footprint_requested": Int(g.footprint(g.entries[big.key]!)), "footprint_used": Int(g.footprint(g.entries[small.key]!)),
        ])
    }

    func testNoLighterEntryRefusesWithoutALoad() async throws {
        let huge = try EngineTestSupport.script([#"{"t":"textDelta","v":"must-not-run"}"#], name: "huge")
        let g = fitGuard([.init(key: huge.key, slot: "chat", engine: "scripted", sizeGB: 20.43, context: 65536)],
                         installed: [huge.key: huge])
        let sup = EngineSupervisorClient(appBuild: "it-fit-none", fitGuard: g)
        defer { sup.disconnect() }
        let ack = try await sup.ensureConnected(timeout: .seconds(25))
        let before = try await sup.current.probe()
        let rssBefore = rss(ack.helperPID)
        var events: [EngineEvent] = []
        for try await e in sup.chat(EngineTestSupport.ask(huge, "keep me")) { events.append(e) }
        XCTAssertEqual(events.count, 1)
        guard case .error(let err)? = events.first else { return XCTFail("expected model.notEnoughMemory, got \(events)") }
        XCTAssertTrue(err.is(.modelNotEnoughMemory), "\(err)")
        XCTAssertEqual(err.recovery, [.retry])
        XCTAssertEqual(err.userMessageKey, "model.notEnoughMemory")
        let after = try await sup.current.probe()
        let rssAfter = rss(ack.helperPID)
        XCTAssertEqual(after.residentModels, before.residentModels, "no load attempted")
        XCTAssertEqual(after.pid, before.pid)
        XCTAssertLessThan(abs(rssAfter - rssBefore), max(rssBefore / 20, 2048), "helper RSS moved: \(rssBefore) → \(rssAfter) KB")
        EngineTestSupport.evidence("AT-208-memory-fit-refuse", [
            "B_bytes": Int(MemoryFitGuard.budget(for: .T0)), "footprint": Int(g.footprint(g.entries[huge.key]!)),
            "helper_rss_kb_before": rssBefore, "helper_rss_kb_after": rssAfter, "resident_before": before.residentModels,
            "resident_after": after.residentModels,
        ])
    }

    func testDevCatalogChainUnderT0() throws {
        // The launch-option path the app uses: ANTICHAT_DEV_CATALOG + -FakeHardware T0.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = repo.appendingPathComponent("catalog/dev-catalog.json")
        var g = try XCTUnwrap(EngineServices.devFitGuard(
            options: LaunchOptions.parse(["-FakeHardware", "T0"]), environment: ["ANTICHAT_DEV_CATALOG": catalog.path]))
        g.freeMemory = { 64_000_000_000 }
        g.resolve = { e in ModelSlot(engine: .mlx, key: e.key, path: "/nonexistent/\(e.key)", contextTokens: e.context) }
        let nine = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/nonexistent/chat-9b-q4", contextTokens: 16384)
        guard case .lighter(let s, let from) = g.check(nine) else { return XCTFail("chat-9b-q4 must not fit B = 4 GB") }
        XCTAssertEqual(from, "chat-9b-q4")
        XCTAssertEqual(s.key, "chat-2b")
        // Evil never falls back (smaller: null) → refused.
        let evil = ModelSlot(engine: .llama, key: "evil-9b", path: "/nonexistent/evil-9b")
        guard case .notEnoughMemory = g.check(evil) else { return XCTFail("evil-9b must be refused at T0") }
    }
}
