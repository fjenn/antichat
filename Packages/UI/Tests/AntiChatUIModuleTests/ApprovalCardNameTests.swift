// M9.T08 (vq-inject capture): the ApprovalCard names the action as people read it, never the raw tool id (a connection's
// tool reads "{app} · {action}" from its MCP descriptor; other tools by the activity lines' readable name).
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ApprovalCardNameTests {
    @Test func cardNamesTheActionReadably() {
        #expect(ApprovalCardView.actionName("write_note") == "Write note")
        #expect(ApprovalCardView.actionName("create_document") == "Create document")
        #expect(!ApprovalCardView.actionName("unknown_tool_id").contains("_"))
    }
}
