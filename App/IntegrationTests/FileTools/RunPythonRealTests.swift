import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class RunPythonRealTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    func testThreeSpreadsheetPromptsProduceFiles() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else {
            throw XCTSkip("RunPythonRealTests requires TIER=T1")
        }
        guard RunPythonTool.installedRuntimePath() != nil else { throw XCTSkip("File tools runtime is not installed") }
        let model = PrefixReuseTests.view("chat-9b-q4")
        guard FileManager.default.fileExists(atPath: model.path) else { throw XCTSkip("chat-9b-q4 is not installed") }
        let slot = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: model.path)
        let engine = EngineClient(appBuild: "it-run-python")
        try await engine.ensureConnected()
        try await engine.setPolicy(SetPolicy(budgetB: UInt64(9.5e9)))
        if let error = await engine.warmup(slot) { throw error }
        defer { engine.disconnect() }
        // AT-018: the three "create_file xlsx" prompts of fixtures/prompts/agentic-30.jsonl (ag-18, ag-19, ag-20), asked
        // with run_python as the only tool, so the file must come out of the sandbox.
        guard let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] else { throw XCTSkip("ANTICHAT_FIXTURES not set") }
        let lines = try String(contentsOfFile: fixtures + "/prompts/agentic-30.jsonl", encoding: .utf8).split(separator: "\n")
        let prompts: [String] = lines.compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  ["ag-18", "ag-19", "ag-20"].contains(row["id"] as? String ?? ""),
                  let messages = row["messages"] as? [[String: Any]], let text = messages.last?["content"] as? String else { return nil }
            return text + " Use run_python and save the file as .xlsx in out/."
        }
        XCTAssertEqual(prompts.count, 3)
        var evidence: [[String: Any]] = []
        for (index, prompt) in prompts.enumerated() {
            let db = try AppDatabase.inMemory()
            let store = ArtifactStore.forDatabase(db)
            let chatID = try ChatRepository(db).create(title: "Run Python real").id
            let registry = ToolRegistry([FileToolsTools.runPython(store: store, database: db)])
            let tools = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(.t1), tier: { .t1 })
            let controller = TurnController(chatID: chatID, database: db, engine: engine, tools: tools) { slot }
            let updates = UpdateBox()
            let listener = Task { for await update in controller.updates { updates.append(update) } }
            let assistantID = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: prompt, parentID: nil), assistantID: assistantID)
            let update = try await updates.finished(assistantID, timeout: .seconds(240))
            listener.cancel()
            let artifacts = try db.read { db in try ArtifactRecord.fetchAll(db) }
            evidence.append(["prompt": index + 1, "status": update.status.rawValue, "artifacts": artifacts.count])
            XCTAssertFalse(artifacts.isEmpty, "prompt \(index + 1) produced no file: \(update.text)")
            XCTAssertTrue(artifacts.contains { $0.kind == "xlsx" })
            try await FileToolsClient(network: false).reset(chatID: chatID)
        }
        FileToolsIT.evidence("AT-018", "real.json", String(decoding: try JSONSerialization.data(withJSONObject: evidence,
                                                                                              options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
