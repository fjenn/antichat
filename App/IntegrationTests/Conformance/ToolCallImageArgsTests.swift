// AT-286 AC1 model leg (M4.T06; R-286, test-strategy §3.2 bar): the T1 chat model (chat-9b-q4) on the `create_image`
// items of fixtures/prompts/agentic-30.jsonl, with the row's create_image tool replaced by the shipped schema
// (CreateImageTool), produces ≥ 90 % schema-valid calls naming create_image. Same runner as AT-231 (ToolEvalRunner).
// `make test-integration-real TIER=T1 FILTER=ToolCallImageArgsTests` (real model: gpu-run.sh shared; memory first).
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatTools
import Foundation
import XCTest

final class ToolCallImageArgsTests: XCTestCase {
    func testCreateImageCallsAreValidOnT1() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ANTICHAT_TIER"] == "T1" else { throw XCTSkip("AT-286 AC1 runs at TIER=T1") }
        guard let row = Conformance.allRows["chat-9b-q4"]?() else { throw XCTSkip("chat-9b-q4 not installed (make models-dev TIER=T1)") }
        let fixtures = URL(fileURLWithPath: env["ANTICHAT_FIXTURES"] ?? RealModels.repoRoot.appendingPathComponent("fixtures").path)
        var rows = try ToolEvalRunner.loadRows(fixtures.appendingPathComponent("prompts/agentic-30.jsonl"))
            .filter { ($0["category"] as? String) == "create_image" }
        XCTAssertGreaterThan(rows.count, 0)
        let schema = try JSONSerialization.jsonObject(with: Data(CreateImageTool.parametersJSON.utf8))
        let shipped: [String: Any] = ["type": "function", "function": ["name": CreateImageTool.name, "description": CreateImageTool.description,
                                                                       "parameters": schema]]
        for i in rows.indices {
            let tools = (rows[i]["tools"] as? [[String: Any]] ?? []).filter { (($0["function"] as? [String: Any])?["name"] as? String) != CreateImageTool.name }
            rows[i]["tools"] = tools + [shipped]
            rows[i]["expected_tool"] = CreateImageTool.name
        }
        let client = try await Conformance.connect(row, build: "it-image-args")
        defer { client.disconnect() }
        let report = await ToolEvalRunner.run(client: client, slot: row.slot, rows: rows, options: .init())
        // The rates live under `metrics` (ToolEvalRunner's report shape, as AT-231 reads them).
        let metrics = report["metrics"] as? [String: Any] ?? [:]
        let valid = metrics["schema_valid_rate"] as? Double ?? 0
        let correct = metrics["correct_tool_rate"] as? Double ?? 0
        RealModels.write("AT-286", "tool-call-image-args.json", ["model": "chat-9b-q4", "rows": rows.count, "schema_valid_rate": valid,
                                                                "correct_tool_rate": correct, "date": ISO8601DateFormatter().string(from: Date())])
        XCTAssertGreaterThanOrEqual(valid, 0.9, "≥ 90 % valid create_image calls (test-strategy §3.2)")
        XCTAssertGreaterThanOrEqual(correct, 0.9)
    }
}
