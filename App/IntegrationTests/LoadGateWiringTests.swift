// M2.T12 leftover (R-294 AC3, M2.T11 step 5): the app-side load gate is on the real turn path. Through the helper
// (ScriptedEngine slots), a load that reaches `.ready` reports ok; a first load that fails (missing model file)
// reports the failure before the turn's stream ends, and the gate's revert makes the next turn ([Retry]) load the
// previous model. A gate refusal (`model.corrupt`) never reaches the helper. ModelUpdateService's side of the same
// contract is UpdateRollbackTests.appGateByModelIDRevertsOnFailedFirstLoad (unit).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import Synchronization
import XCTest

final class RecordingGate: ModelLoadGating {
    let reports = Mutex<[(String, Bool)]>([])
    let remap = Mutex<[String: ModelSlot]>([:])
    let refuse: Set<String>
    let revertTo: ModelSlot?

    init(refuse: Set<String> = [], revertTo: ModelSlot? = nil) {
        self.refuse = refuse
        self.revertTo = revertTo
    }

    func prepare(_ slot: ModelSlot) async -> Result<ModelSlot, AntiChatError> {
        if refuse.contains(slot.key) { return .failure(AntiChatError(.modelCorrupt, detail: "redownload=1")) }
        return .success(remap.withLock { $0[slot.key] } ?? slot)
    }

    func report(_ slot: ModelSlot, ok: Bool) async {
        reports.withLock { $0.append((slot.key, ok)) }
        if !ok, let r = revertTo { remap.withLock { $0[slot.key] = r } }
    }

    var all: [String] { reports.withLock { $0.map { "\($0.0)=\($0.1)" } } }
}

final class LoadGateWiringTests: XCTestCase {
    func collect(_ s: AsyncThrowingStream<EngineEvent, Error>) async throws -> (String, EngineEvent?) {
        var text = ""
        var last: EngineEvent?
        for try await e in s {
            if case .textDelta(let t) = e { text += t }
            last = e
        }
        return (text, last)
    }

    func testFailedFirstLoadReportsAndRetryLoadsThePreviousModel() async throws {
        let previous = try EngineTestSupport.script([#"{"t":"textDelta","v":"from-previous"}"#], name: "gate-prev")
        let broken = ModelSlot.scripted("/nonexistent/\(UUID().uuidString).jsonl", key: "scripted-gate-new")
        let gate = RecordingGate(revertTo: previous)
        let sup = EngineSupervisorClient(appBuild: "it-gate", loadGate: gate)
        defer { sup.disconnect() }
        let (_, first) = try await collect(sup.chat(EngineTestSupport.ask(broken, "hi")))
        guard case .error = first else { return XCTFail("expected a load error, got \(String(describing: first))") }
        XCTAssertEqual(gate.all, ["scripted-gate-new=false"], "verdict lands before the stream ends")
        let (text, last) = try await collect(sup.chat(EngineTestSupport.ask(broken, "retry")))
        XCTAssertEqual(text, "from-previous")
        XCTAssertEqual(last, .done(.stop))
        XCTAssertEqual(gate.all, ["scripted-gate-new=false", "\(previous.key)=true"])
        // Resident now: no load, no second verdict.
        _ = try await collect(sup.chat(EngineTestSupport.ask(broken, "again")))
        XCTAssertEqual(gate.reports.withLock { $0.count }, 2)
        EngineTestSupport.evidence("AT-294-load-gate-wiring", ["reports": gate.all])
    }

    func testWarmupReportsAndGateRefusalNeverReachesTheHelper() async throws {
        let ok = try EngineTestSupport.script([#"{"t":"textDelta","v":"x"}"#], name: "gate-warm")
        let corrupt = try EngineTestSupport.script([#"{"t":"textDelta","v":"must-not-run"}"#], name: "gate-corrupt")
        let gate = RecordingGate(refuse: [corrupt.key])
        let sup = EngineSupervisorClient(appBuild: "it-gate-warm", loadGate: gate)
        defer { sup.disconnect() }
        let err = await sup.warmup(ok, onLifecycle: nil)
        XCTAssertNil(err)
        XCTAssertEqual(gate.all, ["\(ok.key)=true"])
        let before = try await sup.current.probe()
        let (text, last) = try await collect(sup.chat(EngineTestSupport.ask(corrupt)))
        XCTAssertEqual(text, "")
        guard case .error(let e)? = last else { return XCTFail("expected model.corrupt") }
        XCTAssertTrue(e.is(.modelCorrupt), "\(e)")
        let w = await sup.warmup(corrupt, onLifecycle: nil)
        XCTAssertTrue(w?.is(.modelCorrupt) == true)
        let after = try await sup.current.probe()
        XCTAssertEqual(after.residentModels, before.residentModels, "a refused slot is never loaded")
        XCTAssertEqual(gate.all, ["\(ok.key)=true"])
    }

    /// M2.T12 leftover: a SetPolicy pushed mid-session reaches the helper's scheduler (not only at the handshake).
    func testLivePolicyPushReachesTheRunningScheduler() async throws {
        var slot = try EngineTestSupport.script([#"{"t":"textDelta","v":"fits"}"#], name: "gate-policy")
        slot.footprintBytes = 1_000_000
        let sup = EngineSupervisorClient(appBuild: "it-policy", loadGate: RecordingGate())
        defer { sup.disconnect() }
        _ = try await sup.ensureConnected(timeout: .seconds(25))
        XCTAssertGreaterThanOrEqual(EngineClient.pushPolicy(SetPolicy(budgetB: 1000)), 1)
        let (_, refused) = try await collect(sup.chat(EngineTestSupport.ask(slot)))
        guard case .error(let e)? = refused else { return XCTFail("expected notEnoughMemory under B = 1000 B") }
        XCTAssertEqual(e.userMessageKey, "model.notEnoughMemory")
        EngineClient.pushPolicy(SetPolicy(budgetB: 0))
        let (text, _) = try await collect(sup.chat(EngineTestSupport.ask(slot)))
        XCTAssertEqual(text, "fits")
    }

    /// M9.T05 photo.handoff.T1: a client whose owner pinned its policy (`setPolicy`: a hosted test's or a bench's tier
    /// cap) keeps it when the app pushes its own (a thermal / power / keep-alive change in the host app).
    func testAnAppPushDoesNotOverrideAPinnedPolicy() async throws {
        var slot = try EngineTestSupport.script([#"{"t":"textDelta","v":"fits"}"#], name: "gate-pinned")
        slot.footprintBytes = 1_000_000
        let client = EngineClient(appBuild: "it-policy-pinned")
        defer { client.disconnect() }
        XCTAssertTrue(client.followsAppPolicy)
        try await client.setPolicy(SetPolicy(budgetB: 1000))
        XCTAssertFalse(client.followsAppPolicy)
        EngineClient.pushPolicy(SetPolicy(budgetB: 0))  // the host app's policy: must not reach this session
        let (_, refused) = try await collect(client.chat(EngineTestSupport.ask(slot), onLifecycle: nil))
        guard case .error(let e)? = refused else { return XCTFail("the pinned B = 1000 B was overridden by the app push") }
        XCTAssertEqual(e.userMessageKey, "model.notEnoughMemory")
        try await client.setPolicy(SetPolicy(budgetB: 0))
        let (text, _) = try await collect(client.chat(EngineTestSupport.ask(slot), onLifecycle: nil))
        XCTAssertEqual(text, "fits")
    }
}
