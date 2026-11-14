import Testing
@testable import AntiChatEngines

@Suite struct EnginesPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatEnginesModule.name == "AntiChatEngines")
    }
}
