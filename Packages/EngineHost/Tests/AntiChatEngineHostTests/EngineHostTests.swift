import Testing
@testable import AntiChatEngineHost

@Suite struct EngineHostPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatEngineHostModule.name == "AntiChatEngineHost")
    }
}
