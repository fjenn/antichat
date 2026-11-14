import Testing
@testable import AntiChatTools

@Suite struct ToolsPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatToolsModule.name == "AntiChatTools")
    }
}
