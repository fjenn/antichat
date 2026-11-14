import Testing
@testable import AntiChatPlatform

@Suite struct PlatformPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatPlatformModule.name == "AntiChatPlatform")
    }
}
