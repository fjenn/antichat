// M1.T12 AT-208 leg (1) + AT-NFR-S4: `kill -9` the engine helper mid-stream. The test host is AntiChat.app, so
// "the app survives" is this process. Through EngineSupervisorClient (the app's EngineService):
//   - the stream ends with exactly one terminal, `error(engine.restarted)` with recovery [Retry];
//   - a relaunched helper answers HelloAck ≤ 5 s p95 after the SIGKILL (20 runs; ScriptedEngine in the helper on
//     even runs, tiny-mlx-llm on odd runs when the stub is present);
//   - the next send streams;
//   - ≥ 3 restarts in 60 s raise `engine.crashLoop`.
// Runs are spaced ≥ 5.5 s apart: independent crashes, not a crash loop (with two launchd jobs a job is free of the
// 10 s respawn throttle again after ≥ 5 s; ServiceRotation, A-M1-T12a).
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

/// Collects supervisor events off the stream for the test to poll.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EngineSupervisorClient.Event] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EngineSupervisorClient.Event>) {
        task = Task { [weak self] in
            for await e in stream { self?.append(e) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ e: EngineSupervisorClient.Event) { lock.withLock { items.append(e) } }
    var all: [EngineSupervisorClient.Event] { lock.withLock { items } }

    var count: Int { lock.withLock { items.count } }

    /// The first `.restarted` at index ≥ `from` with a pid other than `old`, waiting up to `timeout`; `at` is when
    /// this poll saw it (≤ 2 ms late).
    func restarted(after old: Int32, from: Int, timeout: Duration = .seconds(20)) async -> (pid: Int32, service: String, at: ContinuousClock.Instant)? {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            for e in all.dropFirst(from) {
                if case .restarted(let pid, let service, _) = e, pid != old { return (pid, service, .now) }
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}

final class HelperRestartTests: XCTestCase {
    static let runs = Int(ProcessInfo.processInfo.environment["ANTICHAT_RESTART_RUNS"] ?? "") ?? 20

    /// Streams `slot` until the first text delta, kills the helper, drains the rest. Returns the terminal event,
    /// the kill instant and the deltas seen.
    func killMidStream(_ sup: EngineSupervisorClient, slot: ModelSlot, helper pid: Int32) async throws
        -> (terminal: EngineEvent?, killedAt: ContinuousClock.Instant?, deltas: Int)
    {
        var req = EngineTestSupport.ask(slot)
        req.sampling.maxTokens = 4000
        var killedAt: ContinuousClock.Instant?
        var deltas = 0
        var terminal: EngineEvent?
        for try await e in sup.chat(req) {
            if e.isDelta {
                deltas += 1
                if killedAt == nil {
                    killedAt = .now
                    kill(pid, SIGKILL)
                }
            }
            if e.isTerminal { terminal = e }
        }
        return (terminal, killedAt, deltas)
    }

    func testRestartLatency() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-restart", crashLoop: .init(maxRestarts: 10_000))
        defer { sup.disconnect() }
        let log = EventLog(sup.events())
        let appPID = getpid()
        // The no-EOS copy: the random tiny weights sample `<|im_end|>` as the first token now and then, which ended a
        // run with no delta before the kill ("run 11: no delta before the kill"); without a reachable EOS every MLX
        // run streams until the SIGKILL, deterministically (same fix as M1.T13's XPCCancelTests).
        let mlx = EngineTestSupport.tinyMLXNoEOS
        let scripted = try EngineTestSupport.longStream(tokens: 3000, delayMs: 5)
        var rows: [[String: Any]] = []
        var latencies: [Double] = []
        var retryVisible = 0
        var lastKill: ContinuousClock.Instant?
        // Start from a quiet state: an earlier test may have just killed a young helper of either job.
        while let free = sup.services.compactMap(sup.rotation.freeAt).max(), free > .now {
            try await Task.sleep(for: free - .now)
        }
        for i in 0..<Self.runs {
            if let k = lastKill, ContinuousClock.now - k < .milliseconds(5500) {
                try await Task.sleep(for: .milliseconds(5500) - (ContinuousClock.now - k))
            }
            let ack = try await sup.ensureConnected(timeout: .seconds(20))
            let slot = (i % 2 == 1 && mlx != nil) ? mlx! : scripted
            if slot.engine == .mlx { _ = await sup.warmup(slot) }
            let mark = log.count
            let (terminal, killedAt, deltas) = try await killMidStream(sup, slot: slot, helper: ack.helperPID)
            let k = try XCTUnwrap(killedAt, "run \(i): no delta before the kill")
            lastKill = k
            guard case .error(let err)? = terminal else {
                XCTFail("run \(i): expected error(engine.restarted), got \(String(describing: terminal))")
                continue
            }
            XCTAssertTrue(err.is(.engineRestarted), "run \(i): \(err)")
            if err.recovery.contains(.retry) && err.userMessageKey == "engine.restarted" { retryVisible += 1 }
            let back = await log.restarted(after: ack.helperPID, from: mark)
            let latency = back.map { EngineTestSupport.secs($0.at - k) } ?? .infinity
            latencies.append(latency)
            XCTAssertEqual(getpid(), appPID)
            rows.append([
                "run": i, "engine": slot.engine.rawValue, "old_pid": Int(ack.helperPID), "new_pid": Int(back?.pid ?? 0),
                "service": back?.service ?? "none", "deltas_before_kill": deltas, "kill_to_helloack_s": latency,
            ])
        }
        // The next send after the last restart streams.
        let after = try EngineTestSupport.script([#"{"t":"textDelta","v":"ok"}"#], name: "after-restart")
        var events: [EngineEvent] = []
        for try await e in sup.chat(EngineTestSupport.ask(after)) { events.append(e) }
        XCTAssertEqual(events.last, .done(.stop))

        let sorted = latencies.sorted()
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let p50 = sorted[sorted.count / 2]
        EngineTestSupport.evidence("AT-NFR-S4-restart-latency", [
            "runs": rows, "n": latencies.count, "p50_s": p50, "p95_s": p95, "max_s": sorted.last ?? 0,
            "budget_s": 5.0, "app_alive": "\(Self.runs)/\(Self.runs)", "retry_visible": "\(retryVisible)/\(Self.runs)",
            "tiny_mlx": mlx != nil,
        ])
        XCTAssertLessThanOrEqual(p95, 5.0, "NFR-S4: helper ready ≤ 5 s p95 after SIGKILL (\(sorted))")
        XCTAssertEqual(retryVisible, Self.runs)
    }

    func testCrashLoopRaisesBannerEvent() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-crashloop", crashLoop: .init(maxRestarts: 3, window: .seconds(60)))
        defer { sup.disconnect() }
        let log = EventLog(sup.events())
        for _ in 0..<3 {
            let ack = try await sup.ensureConnected(timeout: .seconds(25))
            let mark = log.count
            kill(ack.helperPID, SIGKILL)
            _ = await log.restarted(after: ack.helperPID, from: mark, timeout: .seconds(25))
        }
        XCTAssertTrue(log.all.contains(.crashLoop(restarts: 3)), "\(log.all)")
        XCTAssertEqual(sup.state, .crashLoop(restarts: 3))
        let banner = AntiChatError(.engineCrashLoop)
        XCTAssertEqual(banner.userMessageKey, "engine.crashLoop")
        XCTAssertEqual(banner.recovery, [.reportProblem, .restartApp])
        // Still usable: a send after the loop streams (the banner informs, it does not block).
        let basic = try EngineTestSupport.script([#"{"t":"textDelta","v":"ok"}"#], name: "after-loop")
        var events: [EngineEvent] = []
        for try await e in sup.chat(EngineTestSupport.ask(basic)) { events.append(e) }
        XCTAssertEqual(events.last, .done(.stop))
        EngineTestSupport.evidence("AT-208-crash-loop", ["events": log.all.map { "\($0)" }])
    }

    /// Why there are two launchd jobs: one job alone is relaunched only after the rest of its 10 s ThrottleInterval
    /// when its helper ran < 10 s. Evidence only (no assertion on launchd's timing); asserts that a client of the
    /// throttled job waits for the relaunch instead of timing out (fix/hello-timeout).
    func testSingleJobRespawnThrottleProbe() async throws {
        let client = EngineClient(appBuild: "it-throttle")
        defer { client.disconnect() }
        // The job's helper may be an old one from an earlier test (no throttle): kill it, then kill the fresh one at 0.5 s.
        var pid: Int32 = 0
        var t0 = ContinuousClock.now
        var throttled = Duration.zero
        for _ in 0..<2 where throttled < .seconds(5) {
            pid = try await client.ensureConnected(timeout: .seconds(25)).helperPID
            try await Task.sleep(for: .milliseconds(500))
            kill(pid, SIGKILL)
            t0 = ContinuousClock.now
            while client.isConnected, ContinuousClock.now - t0 < .seconds(5) { try await Task.sleep(for: .milliseconds(5)) }
            throttled = EngineClient.rotation.throttleRemaining(EngineProtocolVersion.serviceName)
        }
        // fix/hello-timeout: the throttle is waited out on top of the hello budget, so a 5 s budget (a cold helper
        // answers in ≈ 0.1 s, also under load) still reconnects ~9.5 s later instead of failing with helloTimeout.
        XCTAssertGreaterThan(throttled, .seconds(5), "the young helper's death was not recorded")
        let ack = try await client.ensureConnected(timeout: .seconds(5))
        let s = EngineTestSupport.secs(ContinuousClock.now - t0)
        XCTAssertNotEqual(ack.helperPID, pid)
        EngineTestSupport.evidence("AT-NFR-S4-throttle-probe", [
            "helper_age_at_kill_s": 0.5, "same_job_kill_to_helloack_s": s, "service": EngineProtocolVersion.serviceName,
            "throttle_remaining_at_reconnect_s": EngineTestSupport.secs(throttled),
        ])
    }
}
