// M4.T16 round 2 (journey 5 in-app, scripted): the cause of "Draw me a lighthouse" giving an empty reply in a Debug
// build with `-UseScriptedEngine`: the in-process scripted chat engine is not a MediaJobTransport, so ChatEnvironment
// made no MediaJobQueue, registered no create_image / edit_image, the turn offered no tools and the scripted
// toolCallDone was never run. Media jobs now go to the shared XPC helper in that mode (like voice).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ScriptedMediaWiringTests {
    @Test func inProcessScriptedEngineGetsTheHelperAsMediaTransport() throws {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"x"}"#))
        let t = try #require(EngineServices.mediaTransport(for: engine))
        #expect(t is EngineSupervisorClient)
        #expect(EngineServices.mediaTransport(for: engine) as? EngineSupervisorClient === t as? EngineSupervisorClient, "one shared client")
    }
}
