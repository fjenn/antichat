// M8.T09 fix (R-218 AC5): the System report's loaded models and model-load times come from the helper's
// ModelScheduler (resident set + load-time log) over the existing probe message. Stub engine:
//   make test-integration-stub FILTER=SystemReportEngineTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class SystemReportEngineTests: XCTestCase {
    func testProbeCarriesResidentSetAndLoadTimes() async throws {
        var slot = try EngineTestSupport.script([#"{"t":"textDelta","v":"hi"}"#], name: "sysreport")
        slot.footprintBytes = 1_200_000_000
        let client = EngineClient(appBuild: "it-sysreport")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        let before = try await client.probe().loadTimesMs ?? []
        let req = ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "Say hi.")], sampling: Sampling(maxTokens: 4))
        _ = try await EngineTestSupport.drain(client.chatBatches(req))
        let p = try await client.probe()
        XCTAssertEqual(p.residentBytes?[slot.key], 1_200_000_000, "scripted engine: the catalog footprint is the figure")
        let loads = try XCTUnwrap(p.loadTimesMs)
        XCTAssertEqual(loads.count, min(20, before.count + 1), "one load recorded for the turn")
        XCTAssertGreaterThanOrEqual(loads.last ?? -1, 0)
        // The app's path (first connected session; never starts the helper) sees the same state.
        let probed = await EngineClient.probeConnected()
        let connected = try XCTUnwrap(probed)
        XCTAssertNotNil(connected.residentBytes?[slot.key])
        for await _ in client.evict() {}
    }
}
