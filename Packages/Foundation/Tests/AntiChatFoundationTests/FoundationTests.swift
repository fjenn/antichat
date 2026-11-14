import Testing
@testable import AntiChatFoundation

@Suite struct FoundationPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatFoundationModule.name == "AntiChatFoundation")
    }
}
