import Testing
@testable import AntiChatEngineProtocol

@Suite struct EngineProtocolPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatEngineProtocolModule.name == "AntiChatEngineProtocol")
    }
}
