import Testing
@testable import AntiChatNetwork

@Suite struct NetworkPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatNetworkModule.name == "AntiChatNetwork")
    }
}
