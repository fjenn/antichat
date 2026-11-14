// M1.T19 AT-003 leg (5): with the clock fixed at 2026-11-15T09:30+01:00 (the J02 `-FixedClock`), the request the
// engine receives carries the date, the weekday and the local time (date line in the system turn, time line on the
// newest user turn, M1.T14 / D-022).
//   make test-unit FILTER=VolatileDateLineTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("VolatileDateLineTests") struct VolatileDateLineTests {
    @Test func testVolatileDateLine() async throws {
        let fixed = try #require(ISO8601DateFormatter().date(from: "2026-11-15T09:30:00+01:00"))
        let context = VolatileContext(now: fixed, timeZone: try #require(TimeZone(secondsFromGMT: 3600)))
        let engine = InProcessScriptedEngine(script: try EngineScript(text: "{\"t\":\"textDelta\",\"v\":\"ok\"}"))
        let controller = TurnController(
            chatID: StorageID.make(), database: try AppDatabase.inMemory(), engine: engine,
            volatileContext: { context }, slot: { .scripted("d") })
        await controller.start(.send(userID: StorageID.make(), text: "What day is it?", parentID: nil), assistantID: StorageID.make())
        let request = try #require(await controller.lastRequest)
        let text = request.flattenedMessages.map(\.content).joined(separator: "\n")
        #expect(text.contains("2026-11-15"))
        #expect(text.contains("Sunday"))
        #expect(text.contains("09:30"))
        #expect(request.turnContext?.contains("09:30") == true)
    }
}
