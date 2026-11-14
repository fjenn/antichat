// M1.T02 skeleton of the AntiChatIntegrationTests bundle (docs/prd/M1.md convention 3). Hosted by AntiChat.app:
// the helper XPC service and the llama-server helper must be embedded. `ANTICHAT_ENGINES=stub` (make
// test-integration-stub) or `ANTICHAT_TIER=<tier>` (make test-integration-real) select the engine set; the
// suites that use them arrive with M1.T05/T06 (ScriptedEngine) and M1.T12/T13 (real engines).
import Foundation
import XCTest

final class IntegrationHostTests: XCTestCase {
    func testHostedByTheAppWithEmbeddedHelpers() throws {
        let app = Bundle.main.bundleURL
        XCTAssertEqual(app.pathExtension, "app", "integration tests must be hosted by AntiChat.app")
        let xpc = app.appendingPathComponent("Contents/XPCServices/AntiChatEngine.xpc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xpc.path), "missing \(xpc.path)")
        let llama = app.appendingPathComponent("Contents/Helpers/llama-server")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: llama.path), "missing \(llama.path)")
    }

    func testEngineSelectionEnvironment() {
        let env = ProcessInfo.processInfo.environment
        let engines = env["ANTICHAT_ENGINES"], tier = env["ANTICHAT_TIER"]
        // Exactly one of the two make targets set these; a bare xcodebuild run defaults to stub.
        XCTAssertFalse(engines != nil && tier != nil, "ANTICHAT_ENGINES and ANTICHAT_TIER are mutually exclusive")
        if let tier { XCTAssertTrue(["min", "T0", "T1", "T3", "evil-T1"].contains(tier), "unknown tier \(tier)") }
    }
}
