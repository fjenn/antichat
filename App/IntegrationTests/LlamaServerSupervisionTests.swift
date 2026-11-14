// M1.T12 AT-208 leg (1, llama half) + AT-NFR-SEC6, through the real helper and `Contents/Helpers/llama-server`
// with the `tiny-gguf` stub ($ANTICHAT_FIXTURES/stub-models/tiny-gguf/tiny.gguf):
//   - a GGUF turn streams; `kill -9` of llama-server mid-stream ends the turn with engine.restarted while the
//     helper and the app live on, and the next send respawns llama-server and streams (≤ 5 s);
//   - no process of ours listens on TCP (`lsof -iTCP -sTCP:LISTEN` empty for app, helper, llama-server) and
//     llama-server's `--host` is a filesystem path;
//   - `kill -9` of the helper: the bundled llama-watchdog terminates the orphaned llama-server (≤ 3 s grace + poll).
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

enum ProcessTools {
    static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    /// Direct children of `parent` whose executable name is `name`.
    static func children(of parent: Int32, named name: String) -> [Int32] {
        run(["/usr/bin/pgrep", "-P", String(parent), "-x", name]).split(separator: "\n").compactMap { Int32($0) }
    }

    /// Direct children of `parent` whose command line contains `needle` (`ps -axo pid=,ppid=,args=`).
    static func children(of parent: Int32, argsContaining needle: String) -> [(pid: Int32, args: String)] {
        run(["/bin/ps", "-axo", "pid=,ppid=,args="]).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), Int32(f[1]) == parent, f[2].contains(needle) else { return nil }
            return (pid, String(f[2]))
        }
    }

    static func args(_ pid: Int32) -> String {
        run(["/bin/ps", "-o", "args=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The executable file of `pid` (`proc_pidpath`; `ps -o comm` shows argv[0]).
    static func executable(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func tcpListeners(_ pids: [Int32]) -> String {
        run(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ",")])
    }

    /// Every descendant of `root` (children, grandchildren, …) with its command line, from one `ps` snapshot.
    static func descendants(of root: Int32) -> [(pid: Int32, args: String)] {
        var rows: [(pid: Int32, ppid: Int32, args: String)] = []
        for line in run(["/bin/ps", "-axo", "pid=,ppid=,args="]).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) { rows.append((pid, ppid, String(f[2]))) }
        }
        var found: [(pid: Int32, args: String)] = []
        var frontier: Set<Int32> = [root]
        while !frontier.isEmpty {
            let next = rows.filter { frontier.contains($0.ppid) }
            found += next.map { ($0.pid, $0.args) }
            frontier = Set(next.map(\.pid))
        }
        return found
    }

    static func waitGone(_ pid: Int32, timeout: Duration) async -> Double? {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            if !EngineTestSupport.processAlive(pid) { return EngineTestSupport.secs(ContinuousClock.now - t0) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

extension ChatRequest {
    func with(slot: ModelSlot) -> ChatRequest {
        var r = self
        r.modelSlot = slot
        return r
    }
}

final class LlamaServerSupervisionTests: XCTestCase {
    var tiny: ModelSlot!

    override func setUpWithError() throws {
        guard let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] else {
            throw XCTSkip("ANTICHAT_FIXTURES not set (make test-integration-stub FIXTURES=…)")
        }
        let path = URL(fileURLWithPath: f).appendingPathComponent("stub-models/tiny-gguf/tiny.gguf").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("tiny-gguf stub missing at \(path)") }
        tiny = ModelSlot(engine: .llama, key: "tiny-gguf", path: path, contextTokens: 512)
    }

    func ask(_ maxTokens: Int) -> ChatRequest {
        var r = EngineTestSupport.ask(tiny)
        r.sampling.maxTokens = maxTokens
        return r
    }

    /// Loads tiny-gguf and returns (helper pid, llama-server pid).
    func loaded(_ sup: EngineSupervisorClient) async throws -> (Int32, Int32) {
        let helper = try await sup.ensureConnected(timeout: .seconds(25)).helperPID
        let err = await sup.warmup(tiny)
        XCTAssertNil(err)
        let llama = try XCTUnwrap(ProcessTools.children(of: helper, named: "llama-server").first, "no llama-server child of \(helper)")
        return (helper, llama)
    }

    func testTinyGGUFStreamsThroughTheHelper() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-llama")
        defer { sup.disconnect() }
        _ = try await loaded(sup)
        var events: [EngineEvent] = []
        for try await e in sup.chat(ask(16)) { events.append(e) }
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        guard case .done? = events.last else { return XCTFail("expected done, got \(String(describing: events.last))") }
        XCTAssertTrue(events.contains(where: \.isDelta))
    }

    func testKillLlamaServerMidStream() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-llama-kill")
        defer { sup.disconnect() }
        let (helper, llama) = try await loaded(sup)
        var killedAt: ContinuousClock.Instant?
        var terminal: EngineEvent?
        for try await e in sup.chat(ask(4000)) {
            if e.isDelta, killedAt == nil { killedAt = .now; kill(llama, SIGKILL) }
            if e.isTerminal { terminal = e }
        }
        let k = try XCTUnwrap(killedAt)
        guard case .error(let err)? = terminal else { return XCTFail("expected error, got \(String(describing: terminal))") }
        XCTAssertTrue(err.is(.engineRestarted), "\(err)")
        XCTAssertEqual(err.recovery, [.retry])
        // The helper and the app live on; the same session serves the retry.
        XCTAssertTrue(EngineTestSupport.processAlive(helper))
        XCTAssertEqual(sup.current.lastAck?.helperPID, helper)
        var firstDelta: ContinuousClock.Instant?
        var events: [EngineEvent] = []
        for try await e in sup.chat(ask(16)) {
            if e.isDelta, firstDelta == nil { firstDelta = .now }
            events.append(e)
        }
        guard case .done? = events.last else { return XCTFail("retry: expected done, got \(String(describing: events.last))") }
        let retryS = EngineTestSupport.secs(try XCTUnwrap(firstDelta) - k)
        let respawned = ProcessTools.children(of: helper, named: "llama-server")
        XCTAssertFalse(respawned.contains(llama))
        XCTAssertLessThanOrEqual(retryS, 5.0)
        EngineTestSupport.evidence("AT-208-llama-kill", [
            "helper_pid": Int(helper), "killed_llama_pid": Int(llama), "respawned_llama_pids": respawned.map(Int.init),
            "kill_to_first_delta_of_retry_s": retryS, "terminal": "\(err.userMessageKey)",
        ])
    }

    func testNoTCPListener() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-sec6")
        defer { sup.disconnect() }
        let (helper, llama) = try await loaded(sup)
        var events: [EngineEvent] = []
        for try await e in sup.chat(ask(8)) { events.append(e) }
        guard case .done? = events.last else { return XCTFail("chat on tiny-gguf failed: \(String(describing: events.last))") }
        let app = getpid()
        let lsof = ProcessTools.tcpListeners([app, helper, llama])
        let args = ProcessTools.args(llama)
        let host = args.components(separatedBy: " ").drop { $0 != "--host" }.dropFirst().first ?? ""
        let report = """
            # AT-NFR-SEC6 \(ISO8601DateFormatter().string(from: Date()))
            # pids: app=\(app) helper=\(helper) llama-server=\(llama)
            $ lsof -nP -iTCP -sTCP:LISTEN -a -p \(app),\(helper),\(llama)
            \(lsof.isEmpty ? "(no output)" : lsof)
            $ ps -o args= -p \(llama)
            \(args)
            """
        let dir = ProcessInfo.processInfo.environment["ANTICHAT_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try report.write(to: dir.appendingPathComponent("lsof.txt"), atomically: true, encoding: .utf8)
        print(report)
        XCTAssertEqual(lsof, "", "a TCP listener exists:\n\(lsof)")
        XCTAssertTrue(host.hasPrefix("/") && host.hasSuffix(".sock"), "--host is not a socket path: \(args)")
        XCTAssertFalse(args.contains("--api-key"), "the key must not be visible in ps")
    }

    /// CR-S-23: a SetPolicy is applied before any request sent after it on the same session (the budget used to
    /// be set in an unordered Task, so a chat right behind it could be scheduled under the old budget).
    func testSetPolicyAppliesBeforeTheNextRequest() async throws {
        let client = EngineClient(appBuild: "it-policy")
        defer { client.disconnect() }
        var big = tiny!
        big.key = "tiny-gguf-oversized"
        big.footprintBytes = 10_000_000_000
        for i in 0..<20 {
            try await client.setPolicy(SetPolicy(budgetB: 1_000_000_000))
            let events = try await EngineTestSupport.drain(client.chatBatches(ask(4).with(slot: big))).flatMap(\.events)
            guard case .error(let e)? = events.last else { return XCTFail("run \(i): expected a refusal, got \(events)") }
            XCTAssertEqual(e.userMessageKey, "model.notEnoughMemory", "run \(i): \(e)")
            try await client.setPolicy(SetPolicy(budgetB: 0))
        }
        // And the reverse: lifting the cap lets the very next request load.
        let events = try await EngineTestSupport.drain(client.chatBatches(ask(4).with(slot: big))).flatMap(\.events)
        guard case .done? = events.last else { return XCTFail("after SetPolicy(0): \(events.suffix(2))") }
    }

    func testWatchdogTerminatesOrphanedLlamaServer() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-watchdog")
        defer { sup.disconnect() }
        let (helper, llama) = try await loaded(sup)
        let found = ProcessTools.children(of: helper, argsContaining: "--llama-watchdog \(llama)")
        let (watchdog, wargs) = try XCTUnwrap(found.first, "no watchdog for \(llama) under helper \(helper): \(ProcessTools.run(["/bin/ps", "-axo", "pid,ppid,args"]).split(separator: "\n").filter { $0.contains("\(helper)") })")
        XCTAssertTrue(ProcessTools.executable(watchdog).hasSuffix("Contents/Helpers/llama-watchdog"), "not the bundled tool: \(ProcessTools.executable(watchdog)) \(wargs)")
        let watchdogExe = ProcessTools.executable(watchdog)
        kill(helper, SIGKILL)
        let gone = await ProcessTools.waitGone(llama, timeout: .seconds(5))
        let watchdogGone = await ProcessTools.waitGone(watchdog, timeout: .seconds(2))
        XCTAssertNotNil(gone, "llama-server \(llama) orphaned after the helper died")
        XCTAssertNotNil(watchdogGone)
        EngineTestSupport.evidence("AT-208-watchdog", [
            "helper_pid": Int(helper), "llama_pid": Int(llama), "watchdog_pid": Int(watchdog),
            "llama_gone_after_s": gone ?? -1, "watchdog_executable": watchdogExe,
        ])
        await sup.waitForRestart()
    }
    /// fix/orphan-servers (product level): SIGKILL of the engine helper ends EVERY process it spawned — servers,
    /// their own children and the watchdogs — within 5 s, so no model server keeps its GBs after a helper crash.
    func testHelperSIGKILLLeavesNoDescendantWithin5s() async throws {
        let sup = EngineSupervisorClient(appBuild: "it-orphans")
        defer { sup.disconnect() }
        let (helper, llama) = try await loaded(sup)
        let before = ProcessTools.descendants(of: helper)
        XCTAssertTrue(before.contains { $0.pid == llama }, "\(before)")
        XCTAssertTrue(before.contains { $0.args.contains("--llama-watchdog \(llama)") }, "llama-server \(llama) unguarded: \(before)")
        kill(helper, SIGKILL)
        let t0 = ContinuousClock.now
        var survivors = before
        while !survivors.isEmpty, ContinuousClock.now - t0 < .seconds(5) {
            try await Task.sleep(for: .milliseconds(50))
            survivors = survivors.filter { EngineTestSupport.processAlive($0.pid) }
        }
        XCTAssertTrue(survivors.isEmpty, "alive 5 s after the helper's SIGKILL: \(survivors)")
        EngineTestSupport.evidence("orphan-servers-helper-kill", [
            "helper_pid": Int(helper), "descendants": before.count,
            "all_gone_after_s": survivors.isEmpty ? EngineTestSupport.secs(ContinuousClock.now - t0) : -1,
        ])
        await sup.waitForRestart()
    }
}
