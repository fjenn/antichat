import Testing
@testable import AntiChatKnowledge

@Suite struct KnowledgePlaceholderTests {
    @Test func moduleName() {
        #expect(AntiChatKnowledgeModule.name == "AntiChatKnowledge")
    }
}
