import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class RunPythonServiceTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    func testPersistentToolAndHarvestedOutputs() async throws {
        let runtime = try await FileToolsIT.runtime()
        let client = FileToolsClient(network: false)
        let database = try AppDatabase.inMemory()
        let store = ArtifactStore.forDatabase(database)
        let tool = RunPythonTool(runtimePath: { runtime.path }, client: client)
        let chatID = try ChatRepository(database).create(title: "Run Python service").id
        _ = try await tool.run(argumentsJSON: #"{"code":"x = 41"}"#, chatID: chatID,
                               messageID: nil, database: database, store: store)
        let second = try await tool.run(argumentsJSON: #"{"code":"print(x + 1)"}"#, chatID: chatID,
                                        messageID: nil, database: database, store: store)
        let summary = try JSONDecoder().decode(RunPythonSummary.self, from: Data(second.split(separator: "\n").first!.utf8))
        XCTAssertEqual(summary.stdout, "42\n")
        XCTAssertFalse(summary.freshSession)
        let third = try await tool.run(argumentsJSON: #"{"code":"import pandas as pd\nimport matplotlib.pyplot as plt\ndf = pd.DataFrame({'name': ['Alice', 'Bob'], 'age': [34, 29]})\ndf.to_excel('out/ages.xlsx', index=False)\ndf.plot.bar(x='name', y='age')\n"}"#,
                                       chatID: chatID, messageID: nil, database: database, store: store)
        let results = FileOutResult.parseAll(third)
        XCTAssertEqual(Set(results.map(\.format)), ["chart", "xlsx"], third)
        for result in results {
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
            XCTAssertGreaterThan(result.size, 0)
        }
        FileToolsIT.evidence("AT-018", "service.json", String(decoding: try JSONSerialization.data(withJSONObject: [
            "persistent": summary.freshSession == false && summary.stdout == "42\n",
            "outputs": results.map { ["file": $0.file, "format": $0.format, "size": $0.size] },
        ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        try await client.reset(chatID: chatID)
    }
}
