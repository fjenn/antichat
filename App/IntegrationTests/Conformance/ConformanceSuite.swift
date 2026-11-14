// M1.T13 AT-229 (R-229): `make test-integration-real TIER=T1|T3|evil-T1 FILTER=ConformanceSuite` (stub tier:
// `make test-integration-stub FILTER=ConformanceSuite` runs the tiny-mlx plumbing row). For each engine × family row
// of the tier: 40 model tool cases (+ the 10 parser-level recovery rows from ToolCallRecoveryConformanceTests),
// 20 thinking cases, 10 cancel cases, every recorded stream checked by EventOrdering. Each row writes
// build/at/AT-229/rows/<row>-{tools,thinking,cancel}.json; tools/at/conformance-report.py merges them into
// build/at/AT-229/conformance.json. Upstream `xfail`s: none of the cited upstream cases is marked xfail for these
// families at the pinned commits, so every failure counts.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class ConformanceSuite: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
        if Conformance.rows.isEmpty { throw XCTSkip("no conformance row for this tier (ANTICHAT_TIER / ANTICHAT_CONFORMANCE_ROWS)") }
    }

    private func perRow(_ suffix: String, _ body: (EngineClient, ConformanceRow) async throws -> [String: Any]) async throws {
        for row in Conformance.rows {
            let client = try await Conformance.connect(row, build: "it-conformance-\(suffix)")
            defer { client.disconnect() }
            let t0 = ContinuousClock.now
            var report = try await body(client, row)
            report["row"] = row.id
            report["engine"] = row.engine
            report["family"] = row.family
            report["model"] = row.slot.key
            report["cap"] = row.cap
            report["date"] = Conformance.date
            report["runtime_s"] = EngineTestSupport.secs(ContinuousClock.now - t0)
            Conformance.write("\(row.id)-\(suffix)", report)
            report["plumbing"] = row.plumbing
            let contract = ["ordering", "events after", "error:", "cancel →"]
            let failed = (report["cases"] as? [[String: Any]] ?? []).filter { c in
                guard (c["pass"] as? Bool) != true else { return false }
                guard row.plumbing else { return true }
                let why = (c["why"] as? [String] ?? [])
                return why.contains { w in contract.contains { w.contains($0) } }
                    && !(c["phase"] as? String == "reasoning" && why.contains { $0.contains("done:stop") })
            }
            XCTAssertTrue(failed.isEmpty, "\(row.id) \(suffix): \(failed.count) failing: \(failed.map { "\($0["id"] ?? "?"): \($0["why"] ?? "")" })")
        }
    }

    func testToolCases() async throws {
        let cases = try Conformance.loadJSONL("conformance/tools-50.jsonl").filter { ($0["kind"] as? String) != "recovery" }
        XCTAssertEqual(cases.count, 40)
        try await perRow("tools") { client, row in
            var out: [[String: Any]] = []
            for c in cases {
                let r = await ToolCallCases.run(client, row, c)
                print("[\(row.id)] \(r.id) \(r.pass ? "PASS" : "FAIL") \(r.calls) \(r.why)")
                out.append(r.json)
            }
            let calls = out.reduce(0) { $0 + (($1["calls"] as? [String])?.count ?? 0) }
            let constrained = out.reduce(0) { $0 + max(0, ($1["constrained"] as? Int) ?? 0) }
            return ["cases": out, "passed": out.filter { $0["pass"] as? Bool == true }.count, "total": out.count,
                    "calls": calls, "constrained_calls": constrained]
        }
    }

    func testThinkingCases() async throws {
        let cases = try Conformance.loadJSONL("conformance/thinking-20.jsonl")
        XCTAssertEqual(cases.count, 20)
        try await perRow("thinking") { client, row in
            var out: [[String: Any]] = []
            for c in cases {
                let r = await ThinkingCases.run(client, row, c)
                print("[\(row.id)] \(r["id"] ?? "?") \((r["pass"] as? Bool) == true ? "PASS" : "FAIL") \(r["why"] ?? "")")
                out.append(r)
            }
            return ["cases": out, "passed": out.filter { $0["pass"] as? Bool == true }.count, "total": out.count]
        }
    }

    func testCancelCases() async throws {
        let cases = try Conformance.loadJSONL("conformance/cancel-10.jsonl")
        XCTAssertEqual(cases.count, 10)
        try await perRow("cancel") { client, row in
            var out: [[String: Any]] = []
            for c in cases {
                let r = await CancelCases.run(client, row, c)
                print("[\(row.id)] \(r["id"] ?? "?") \((r["pass"] as? Bool) == true ? "PASS" : "FAIL") \(r["cancel_ms"] ?? -1) ms \(r["why"] ?? "")")
                out.append(r)
            }
            let ms = out.compactMap { $0["cancel_ms"] as? Double }
            return ["cases": out, "passed": out.filter { $0["pass"] as? Bool == true }.count, "total": out.count,
                    "max_cancel_ms": ms.max() ?? -1]
        }
    }
}
