// M6.T18 AT-NFR-SEC3 (NFR-SEC3, R-018 AC5): `make test-integration-stub FILTER=SecuritySuiteTests`. Every fixture of
// fixtures/sandbox/security (01_socket … 08_read_app_support) runs ANTICHAT_SEC3_REPS times (default 10) through the
// real signed File tools slot services (AntiChatFileTools[Net]Slot<k>.xpc) on the real signed runtime, each in a fresh chat, and must end denied or killed
// with the exact notice key of expected.json (SandboxNotice). Also: memory peak ≤ cap + 5 %, the 60 s wall clock
// ± 1 s, CPU p95 ≤ 200 % during 06 (A-M6-07), and a concurrent chat's run still answers within 2 s while 06 runs
// AND a second chat runs a loop (A-M6-T21a (a): N−1 = 2 of the 3 slots busy; the bystander gets the third).
// Any output line starting with "ESCAPED" fails the suite (S0, test-strategy §10).
// Evidence: build/at/AT-NFR-SEC3/<date>/suite.json.
import AntiChatEngineProtocol
import AntiChatTools
import Foundation
import XCTest

final class SecuritySuiteTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    /// Its own leaser over the dev slot ids, all 3 slots (each fixture rep is a new chat: every run moves a lease).
    let client = FileToolsClient(network: false, slots: FileToolsSlots(capacity: FileToolsProtocol.maxSlots))
    static let dir = FileToolsIT.repo.appending(path: "fixtures/sandbox/security")
    var reps: Int { Int(ProcessInfo.processInfo.environment["ANTICHAT_SEC3_REPS"] ?? "") ?? 10 }

    struct Row: Codable { var fixture: String; var rep: Int; var outcome: String; var reason: String?; var notice: String?
        var pass: Bool; var wallSeconds: Double; var peakFootprintBytes: Int64; var cpuPercent: Double; var detail: String
        var watchdogMaxGapMs: Double?; var watchdogRealtime: Bool?; var asleepSeconds: Double? }

    func testEveryFixtureIsDeniedOrKilledWithItsNotice() async throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.dir.appending(path: "expected.json"))) as! [String: [String: String]]
        let canary = "\(FileToolsIT.home)/.antichat-sec3-canary-\(UUID().uuidString.prefix(8)).txt"
        try "secret".write(toFile: canary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: canary) }
        var rows: [Row] = []
        var cpu06: [Double] = []
        var concurrentMax = 0.0
        // ANTICHAT_SEC3_ONLY=<fixture>[,<fixture>] narrows a diagnostic run (the gate runs all eight).
        let only = Set((ProcessInfo.processInfo.environment["ANTICHAT_SEC3_ONLY"] ?? "").split(separator: ",").map(String.init))
        for name in expected.keys.sorted() where only.isEmpty || only.contains(name) {
            let want = expected[name]!
            let code = try String(contentsOf: Self.dir.appending(path: "\(name).py"), encoding: .utf8)
                .replacingOccurrences(of: "__CANARY__", with: canary).replacingOccurrences(of: "__HOME__", with: FileToolsIT.home)
            for rep in 1...reps {
                let chat = "sec3-\(name.prefix(2))-\(rep)"
                var bystander: Task<(Double, String), Error>?
                var busy2: Task<RunResult, Error>?
                if name == "06_infinite_loop" {  // another chat keeps answering while the loop burns its 60 s
                    let c = client
                    busy2 = Task { try await FileToolsIT.run(c, chat: "sec3-busy2-\(rep)", "while True: pass", timeout: 20).0 }
                    bystander = Task {
                        try await Task.sleep(for: .seconds(5))
                        let t0 = Date()
                        let (r, _) = try await FileToolsIT.run(c, chat: "sec3-bystander", "print(6 * 7)")
                        return (Date().timeIntervalSince(t0), r.stdout)
                    }
                }
                let (r, _) = try await FileToolsIT.run(client, chat: chat, code, timeout: FileToolsProtocol.defaultTimeoutSeconds)
                if let b = bystander {
                    let (t, out) = try await b.value
                    XCTAssertEqual(out, "42\n")
                    concurrentMax = max(concurrentMax, t)
                }
                if let b2 = busy2 {
                    let r2 = try await b2.value
                    XCTAssertEqual(r2.killedReason, .timeout, "the second busy chat")
                    _ = try? await client.reset(chatID: "sec3-busy2-\(rep)")
                }
                let notice = SandboxNotice.for(r)
                let outcome = r.killedReason != nil || notice?.key == "sandbox.killed" ? "killed" : (notice != nil ? "denied" : "ran")
                var pass = outcome == want["outcome"] && notice?.key == want["notice"] && !r.stdout.contains("ESCAPED")
                if let wr = want["reason"] { pass = pass && (notice?.reasonKey == "sandbox.reason.\(wr)" || r.killedReason?.rawValue == wr) }
                if name == "05_alloc_10g", r.killedReason == .memory {
                    pass = pass && Double(r.peakFootprintBytes) <= Double(FileToolsProtocol.memoryCapBytes) * 1.05
                }
                if name == "06_infinite_loop" {
                    pass = pass && abs(r.wallSeconds - FileToolsProtocol.defaultTimeoutSeconds) <= 1.0
                    cpu06.append(r.cpuPercent)
                }
                let detail = r.error.map { "\($0.type): \($0.message)" } ?? r.serviceError ?? String(r.stdout.prefix(200))
                rows.append(Row(fixture: name, rep: rep, outcome: outcome, reason: r.killedReason?.rawValue, notice: notice?.key,
                                pass: pass, wallSeconds: r.wallSeconds, peakFootprintBytes: r.peakFootprintBytes,
                                cpuPercent: r.cpuPercent, detail: detail, watchdogMaxGapMs: r.watchdogMaxGapMs,
                                watchdogRealtime: r.watchdogRealtime, asleepSeconds: r.asleepSeconds))
                XCTAssertTrue(pass, "\(name) rep \(rep): outcome \(outcome) notice \(notice?.key ?? "-") reason \(r.killedReason?.rawValue ?? "-") wall \(r.wallSeconds) peak \(r.peakFootprintBytes) — \(detail)")
                _ = try? await client.reset(chatID: chat)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/antichat-sec3-escape.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(FileToolsIT.home)/Desktop/antichat-sec3-escape.txt"))
        let sorted = cpu06.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        XCTAssertLessThanOrEqual(p95, 200, "CPU p95 during 06 (A-M6-07)")
        XCTAssertLessThan(concurrentMax, 2.0, "a concurrent chat must answer within 2 s")
        let passed = rows.filter(\.pass).count
        let load = FileToolsIT.shell("/usr/bin/uptime", [])
        let summary: [String: Any] = [
            "fixtures": expected.count, "reps": reps, "runs": rows.count, "passed": passed,
            "pass_rate": rows.isEmpty ? 0 : Double(passed) / Double(rows.count),
            "cpu_p95_06": p95, "concurrent_answer_max_s": concurrentMax, "bystander_other_chats_busy": 2,
            "slots": FileToolsProtocol.maxSlots, "memory_cap_bytes": FileToolsProtocol.memoryCapBytes,
            "uptime": load.trimmingCharacters(in: .whitespacesAndNewlines),
            "rows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
        ]
        FileToolsIT.evidence("AT-NFR-SEC3", "suite.json", String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        _ = try? await client.reset(chatID: "sec3-bystander")
    }
}
