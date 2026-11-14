// M1.T12: the pure parts of the restart choreography and the memory-fit guard (no XPC).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ServiceRotationTests") struct ServiceRotationTests {
    let a = "job.a", b = "job.b"

    @Test func prefersThePrimaryWhenBothAreFree() {
        let r = ServiceRotation()
        #expect(r.pick([a, b]) == a)
    }

    @Test func aYoungHelperThrottlesItsJobSoTheOtherIsUsed() {
        let r = ServiceRotation()
        let t0 = ContinuousClock.now
        r.connected(a, pid: 10, at: t0)
        r.died(a, at: t0 + .seconds(2))  // ran 2 s → launchd frees it at t0 + 2 + 8
        #expect(r.freeAt(a) == t0 + .seconds(10))
        #expect(r.pick([a, b], preferring: a, now: t0 + .seconds(2)) == b)
        // b dies young too, before a is free: the one free soonest wins.
        r.connected(b, pid: 11, at: t0 + .seconds(2))
        r.died(b, at: t0 + .seconds(3))
        #expect(r.pick([a, b], preferring: b, now: t0 + .seconds(3)) == a)
        // After both throttles: primary again.
        #expect(r.pick([a, b], now: t0 + .seconds(30)) == a)
    }

    @Test func anOldHelperIsFreeAtOnceButARestartStillMovesJobs() {
        let r = ServiceRotation()
        let t0 = ContinuousClock.now
        r.connected(a, pid: 10, at: t0)
        r.died(a, at: t0 + .seconds(60))
        #expect(r.freeAt(a) == t0 + .seconds(60))
        #expect(r.pick([a, b], preferring: a, now: t0 + .seconds(60)) == b)
    }

    @Test func aRepeatedAckFromTheSamePidKeepsItsStartTime() {
        let r = ServiceRotation()
        let t0 = ContinuousClock.now
        r.connected(a, pid: 10, at: t0)
        r.connected(a, pid: 10, at: t0 + .seconds(9))
        r.died(a, at: t0 + .seconds(12))
        #expect(r.freeAt(a) == t0 + .seconds(12))
    }

    /// fix/hello-timeout: every session to a helper reports its death; only the first record counts (a second one
    /// would restart the throttle as if a 0 s helper had died), and a stale pid's death changes nothing.
    @Test func oneHelperDeathReportedByManySessionsIsRecordedOnce() {
        let r = ServiceRotation()
        let t0 = ContinuousClock.now
        r.connected(a, pid: 10, at: t0)
        r.died(a, pid: 10, at: t0 + .seconds(2))
        r.died(a, pid: 10, at: t0 + .seconds(2.5))
        #expect(r.freeAt(a) == t0 + .seconds(10))
        r.connected(a, pid: 11, at: t0 + .seconds(10))
        r.died(a, pid: 10, at: t0 + .seconds(11))  // late report of the old helper
        #expect(r.freeAt(a) == t0 + .seconds(10))
    }

    /// fix/hello-timeout: the hello timeout of a client of a throttled job starts counting only when launchd may
    /// start its helper again.
    @Test func throttleRemainingIsTheWaitUntilLaunchdRelaunches() {
        let r = ServiceRotation()
        let t0 = ContinuousClock.now
        #expect(r.throttleRemaining(a, now: t0) == .zero)
        r.connected(a, pid: 10, at: t0)
        r.died(a, pid: 10, at: t0 + .milliseconds(200))
        #expect(r.throttleRemaining(a, now: t0 + .milliseconds(600)) == .milliseconds(9400))
        #expect(r.throttleRemaining(a, now: t0 + .seconds(11)) == .zero)
        #expect(r.throttleRemaining(b, now: t0 + .seconds(1)) == .zero)
    }
}

@Suite("MemoryFitGuardTests") struct MemoryFitGuardTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func devGuard(budget: UInt64?, free: UInt64 = 200_000_000_000, installed: Set<String>? = nil) throws -> MemoryFitGuard {
        let entries = try MemoryFitGuard.loadDevCatalog(Self.repoRoot.appendingPathComponent("catalog/dev-catalog.json"))
        return MemoryFitGuard(entries: entries, budgetBytes: budget, freeMemory: { free }) { e in
            guard installed?.contains(e.key) ?? true else { return nil }
            return ModelSlot(engine: EngineKind(rawValue: e.engine) ?? .mlx, key: e.key, path: "/nonexistent/\(e.key)", contextTokens: e.context)
        }
    }

    func slot(_ key: String, ctx: Int? = nil) -> ModelSlot { ModelSlot(engine: .mlx, key: key, path: "/nonexistent/\(key)", contextTokens: ctx) }

    @Test func budgetsFollowNFRR1() {
        #expect(MemoryFitGuard.budget(for: .T0) == 4_000_000_000)
        #expect(MemoryFitGuard.budget(for: .T1) == 9_500_000_000)
        #expect(MemoryFitGuard.budget(for: .T3) == 36_000_000_000)
    }

    @Test func footprintIsSizeTimesOnePointTwoPlusKV() throws {
        let g = try devGuard(budget: nil)
        let e = try #require(g.entries["chat-9b-q4"])
        #expect(g.footprint(e) == UInt64(5.98 * 1e9 * 1.2) + 16384 * g.fallbackKVBytesPerToken)
    }

    @Test func fitsAtT1() throws {
        let g = try devGuard(budget: MemoryFitGuard.budget(for: .T1))
        #expect(g.check(slot("chat-9b-q4", ctx: 16384)) == .fits(slot("chat-9b-q4", ctx: 16384)))
    }

    @Test func walksTheSmallerChainToTheFirstInstalledEntryThatFits() throws {
        // T0: 35b → g26 → 9b all exceed 4 GB; chat-2b (2.1 GB + KV) fits.
        let g = try devGuard(budget: MemoryFitGuard.budget(for: .T0))
        guard case .lighter(let s, let from) = g.check(slot("chat-35b-q4")) else { Issue.record("expected lighter"); return }
        #expect(from == "chat-35b-q4")
        #expect(s.key == "chat-2b")
        // chat-2b not installed → chat-0.8b.
        let g2 = try devGuard(budget: MemoryFitGuard.budget(for: .T0), installed: ["chat-0.8b"])
        guard case .lighter(let s2, _) = g2.check(slot("chat-9b-q4")) else { Issue.record("expected lighter"); return }
        #expect(s2.key == "chat-0.8b")
    }

    @Test func refusesWhenNothingFitsOrTheSlotHasNoFallback() throws {
        let g = try devGuard(budget: MemoryFitGuard.budget(for: .T0), installed: [])
        guard case .notEnoughMemory(let e) = g.check(slot("chat-9b-q4")) else { Issue.record("expected refusal"); return }
        #expect(e.userMessageKey == "model.notEnoughMemory")
        #expect(e.recovery == [.retry])
        let evil = ModelSlot(engine: .llama, key: "evil-9b", path: "/nonexistent/evil-9b")
        guard case .notEnoughMemory = try devGuard(budget: MemoryFitGuard.budget(for: .T0)).check(evil) else {
            Issue.record("evil never falls back (smaller: null)"); return
        }
    }

    @Test func freeMemoryCountsEvenWithoutATierCap() throws {
        let g = try devGuard(budget: nil, free: 3_000_000_000)
        guard case .lighter(let s, _) = g.check(slot("chat-9b-q4")) else { Issue.record("expected lighter"); return }
        #expect(s.key == "chat-2b")
        #expect(MemoryFitGuard.availableMemory() > 0)
    }

    @Test func unknownKeysAndScriptedSlotsPassThrough() throws {
        let g = try devGuard(budget: 1)
        let s = ModelSlot.scripted("/tmp/x.jsonl", key: "scripted-x")
        #expect(g.check(s) == .fits(s))
    }

    @Test func kvFromAnMLXConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = #"{"text_config":{"num_hidden_layers":32,"num_attention_heads":16,"num_key_value_heads":4,"head_dim":256}}"#
        try Data(cfg.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(MemoryFitGuard.readConfig(dir.path) == UInt64(2 * 32 * 4 * 256 * 2))
    }
}
