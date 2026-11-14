// The composition root's voice wiring: the shared voice client must carry a memory-fit guard in the real app, whether
// chat runs over XPC (the supervisor's own guard is reused) or replays in-process (`EngineServices.appFitGuard()`).
// Fails if `AppVoiceWiring.attach` stops setting it, or if the voice client is built without it.
//   make test-unit FILTER=AppVoiceWiringTests
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.serialized, .isolatedSettings) struct AppVoiceWiringTests {
    @Test func voiceClientCarriesTheAppFitGuard() throws {
        let scripted = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok","delayMs":1}"#))
        AppVoiceWiring.attach(engine: scripted)
        let voice = try #require(EngineServices.voice(for: scripted) as? EngineSupervisorClient)
        #expect(voice.fitGuard != nil, "the real wiring leaves the voice client's memory-fit guard nil")
    }

    @Test func supervisorEngineSharesItsGuard() {
        let guard_ = MemoryFitGuard(entries: ["x": .init(key: "x", slot: "chat", engine: "mlx", sizeGB: 1)], budgetBytes: 1,
                                    resolve: { _ in nil })
        let engine = EngineSupervisorClient(appBuild: "test", fitGuard: guard_)
        AppVoiceWiring.attach(engine: engine)
        #expect(EngineServices.voice(for: engine) === engine, "XPC chat: voice goes to the same supervised client")
        #expect((EngineServices.voice(for: engine) as? EngineSupervisorClient)?.fitGuard?.entries.keys.contains("x") == true)
    }
}
