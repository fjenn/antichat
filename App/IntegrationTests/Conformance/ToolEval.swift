// M1.T13 AT-231 (R-231): `make test-integration-real TIER=T1 FILTER=ToolEval` — the 200-prompt tool eval on the T1
// default (chat-9b-q4 at the T1 cap) through the real helper; same runner as `antichat-bench tools`. Writes
// build/at/AT-231/tools.json. Gates: constrained for every call, parse/schema ≥ 0.98, correct tool ≥ 0.90, 0 leaks.
// `ANTICHAT_TOOL_EVAL_MODEL` / `ANTICHAT_TOOL_EVAL_LIMIT` override the model / row count (plumbing runs).
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class ToolEval: XCTestCase {
    func testToolEval200OnT1Default() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = env["ANTICHAT_TOOL_EVAL_MODEL"] ?? "chat-9b-q4"
        guard env["ANTICHAT_TIER"] == "T1" || env["ANTICHAT_TOOL_EVAL_MODEL"] != nil else { throw XCTSkip("AT-231 runs at TIER=T1") }
        guard let row = Conformance.allRows[key]?() else { throw XCTSkip("\(key) not installed (make models-dev TIER=T1)") }
        var rows = try ToolEvalRunner.loadRows(Conformance.casesDir.appendingPathComponent("antichat-tools-200.jsonl"))
        XCTAssertEqual(rows.count, 200)
        // Diagnostics: `ANTICHAT_TOOL_EVAL_IDS=a,b` runs only those rows (report tools-<model>-ids.json).
        let ids = env["ANTICHAT_TOOL_EVAL_IDS"].map { Set($0.split(separator: ",").map(String.init)) }
        if let ids { rows = rows.filter { ids.contains($0["id"] as? String ?? "") } }
        let client = try await Conformance.connect(row, build: "it-tool-eval")
        defer { client.disconnect() }
        let limit = env["ANTICHAT_TOOL_EVAL_LIMIT"].flatMap(Int.init)
        // M1.T16: `ANTICHAT_TOOL_SELECTION=standard` runs the app's ToolSelection in front of every row (report
        // tools-selection-<variant>-….json; tools.json stays the M1.T13 eval).
        let selection = env["ANTICHAT_TOOL_SELECTION"].flatMap(ToolSelection.Variant.init(rawValue:)) ?? .off
        let overhead = limit == nil && ids == nil && selection == .off ? 30 : 0
        var report = await ToolEvalRunner.run(
            client: client, slot: row.slot, rows: rows, options: .init(limit: limit, overheadRows: overhead, selection: selection)) {
            print("[tool-eval] \($0)")
        }
        report["cap"] = row.cap
        report["date"] = Conformance.date
        report["via"] = "make test-integration-real TIER=T1 FILTER=ToolEval"
        report["selection"] = selection.rawValue
        var name = limit == nil && ids == nil && key == "chat-9b-q4" ? "tools.json" : "tools-\(key)-\(ids == nil ? String(limit ?? 200) : "ids").json"
        if selection != .off { name = "tools-selection-\(selection.rawValue)-" + name }
        let out = Conformance.repoRoot.appendingPathComponent("build/at/AT-231/\(name)")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        let m = report["metrics"] as? [String: Any] ?? [:]
        print("[tool-eval] metrics \(m) → \(out.path)")
        if ids != nil || limit != nil { return }  // diagnostics subset: no gate
        XCTAssertGreaterThanOrEqual(m["parse_valid_rate"] as? Double ?? 0, 0.98)
        XCTAssertGreaterThanOrEqual(m["schema_valid_rate"] as? Double ?? 0, 0.98)
        XCTAssertGreaterThanOrEqual(m["correct_tool_rate"] as? Double ?? 0, 0.90)
        XCTAssertEqual(m["raw_syntax_leaks"] as? Int ?? -1, 0)
        XCTAssertEqual(m["constrained_rate"] as? Double ?? 0, 1.0, "every call grammar-constrained (trace flag)")
    }
}
