// M1.T05 gate: `make test-integration-stub FILTER=XPCHandshakeTests` — Hello/HelloAck, version mismatch → the
// helper answers engine.versionMismatch and exits; a helper death ends open streams with engine.restarted and the
// next request reconnects to a relaunched helper.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class XPCHandshakeTests: XCTestCase {
    func testHandshakeReportsCapabilities() async throws {
        let client = EngineClient(appBuild: "it-handshake")
        defer { client.disconnect() }
        XCTAssertFalse(client.isConnected, "no XPC before the first request (architecture §4.2)")
        let ack = try await client.ensureConnected()
        XCTAssertEqual(ack.protocolVersion, EngineProtocolVersion.current)
        XCTAssertGreaterThan(ack.helperPID, 0)
        XCTAssertNotEqual(ack.helperPID, getpid(), "the engine runs in its own process")
        XCTAssertTrue(ack.capabilities.engines.contains(.mlx))
        XCTAssertTrue(ack.capabilities.engines.contains(.scripted))
        XCTAssertEqual(ack.capabilities.batch, .standard)
        let caps = await client.capabilities()
        XCTAssertEqual(caps, ack.capabilities)
    }

    func testVersionMismatchMakesTheHelperExit() async throws {
        let good = EngineClient(appBuild: "it-good")
        defer { good.disconnect() }
        let pid = try await good.ensureConnected().helperPID
        let bad = EngineClient(appBuild: "it-stale")
        defer { bad.disconnect() }
        do {
            _ = try await bad.connect(timeout: .seconds(5), protocolVersion: EngineProtocolVersion.current - 1)
            XCTFail("a stale protocol version must be refused")
        } catch let e as AntiChatError {
            XCTAssertTrue(e.is(.engineVersionMismatch), "got \(e)")
            XCTAssertEqual(e.userMessageKey, "engine.versionMismatch")
        }
        let t0 = ContinuousClock.now
        while EngineTestSupport.processAlive(pid), ContinuousClock.now - t0 < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let exitS = EngineTestSupport.secs(ContinuousClock.now - t0)
        XCTAssertFalse(EngineTestSupport.processAlive(pid), "helper \(pid) still running after a mismatched Hello")
        // launchd relaunches the service on the next message; a current client works again. A service that ran
        // < 10 s gets its respawn deferred by launchd's 10 s throttle ("Service only ran for 0 seconds. Pushing
        // respawn out by 10 seconds"), hence the long handshake timeout here.
        let again = EngineClient(appBuild: "it-again")
        defer { again.disconnect() }
        let ack = try await again.ensureConnected(timeout: .seconds(20))
        XCTAssertNotEqual(ack.helperPID, pid)
        EngineTestSupport.evidence("xpc-handshake-mismatch", ["old_pid": Int(pid), "new_pid": Int(ack.helperPID), "exit_s": exitS])
    }

    func testHelperDeathEndsStreamsWithRestartedAndReconnects() async throws {
        let client = EngineClient(appBuild: "it-crash")
        defer { client.disconnect() }
        let pid = try await client.ensureConnected().helperPID
        let slot = try EngineTestSupport.script(
            [#"{"t":"textDelta","v":"a","delayMs":10,"repeat":20}"#, #"{"t":"crash"}"#], name: "crash")
        let batches = try await EngineTestSupport.drain(client.chatBatches(EngineTestSupport.ask(slot)))
        let events = batches.flatMap(\.events)
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        guard case .error(let e)? = events.last else { return XCTFail("expected engine.restarted, got \(events.suffix(2))") }
        XCTAssertTrue(e.is(.engineRestarted), "got \(e)")
        // Next request reconnects to a new helper (launchd may defer the respawn by its 10 s throttle).
        try await client.ensureConnected(timeout: .seconds(20))
        let basic = try EngineTestSupport.script([#"{"t":"textDelta","v":"ok"}"#], name: "after")
        let after = try await EngineTestSupport.drain(client.chatBatches(EngineTestSupport.ask(basic))).flatMap(\.events)
        XCTAssertEqual(after.last, .done(.stop))
        XCTAssertNotEqual(client.lastAck?.helperPID, pid)
    }

    func testChatStreamContract() async throws {
        let client = EngineClient(appBuild: "it-contract")
        defer { client.disconnect() }
        let slot = try EngineTestSupport.script([
            #"{"t":"load","ms":100,"steps":2}"#, #"{"t":"reasoningDelta","v":"hm","delayMs":5}"#,
            #"{"t":"textDelta","v":"Hel","delayMs":5}"#, #"{"t":"textDelta","v":"lo"}"#,
            #"{"t":"toolCallDone","id":"c1","name":"echo","args":"{}"}"#,
        ], name: "contract")
        let life = LifecycleLog()
        var events: [EngineEvent] = []
        for try await e in client.chat(EngineTestSupport.ask(slot), onLifecycle: { life.add($0) }) { events.append(e) }
        XCTAssertEqual(events.filter(\.isTerminal), [.done(.toolCalls)])
        let text = events.compactMap { if case .textDelta(let s) = $0 { s } else { nil } }.joined()
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(events.contains(.toolCallDone(id: "c1", name: "echo", argsJSON: "{}")))
        XCTAssertTrue(life.all.contains(.loadState(.ready)))
    }
}

final class LifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LifecycleEvent] = []
    func add(_ e: LifecycleEvent) { lock.withLock { items.append(e) } }
    var all: [LifecycleEvent] { lock.withLock { items } }
}
