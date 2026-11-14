import Testing
@testable import AntiChatHarness

@Suite struct HarnessPlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatHarnessModule.name == "AntiChatHarness")
    }
}
