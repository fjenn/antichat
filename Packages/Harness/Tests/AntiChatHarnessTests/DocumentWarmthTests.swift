// M6.T03 step 1: a prompt with a whole document gets a prefix pin whose hash is the same on the follow-up (the
// document stays in place); a prompt with only excerpts or none gets no pin.
//   make test-unit FILTER=DocumentWarmthTests
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct DocumentWarmthTests {
    func req(_ msgs: [ChatMessage]) -> ChatRequest {
        ChatRequest(modelSlot: .scripted("x"), messages: [.layer(PromptLayer(id: "base", content: "You are AntiChat."))] + msgs.map(PromptItem.message))
    }
    let doc = "<document name=\"a.pdf\" pages=\"2\" untrusted=\"true\">\nhello\n</document>"

    @Test func wholeDocumentPinsAndFollowUpsKeepTheHash() throws {
        let first = try #require(DocumentWarmth.pin(for: req([ChatMessage(role: .user, content: doc + "\n\nSummarise")]), chatID: "c"))
        let follow = try #require(DocumentWarmth.pin(for: req([
            ChatMessage(role: .user, content: doc + "\n\nSummarise"), ChatMessage(role: .assistant, content: "It says hello."),
            ChatMessage(role: .user, content: "And page 2?"),
        ]), chatID: "c"))
        #expect(first.prefixHash == follow.prefixHash && first.chatID == "c" && first.prefixHash.count == 64)
    }

    @Test func excerptsOrNothingAreNotPinned() {
        #expect(DocumentWarmth.pin(for: req([ChatMessage(role: .user, content: "hi")]), chatID: "c") == nil)
        let ex = "<excerpt source=\"a.pdf\" page=\"3\" untrusted=\"true\">\nx\n</excerpt>\n\nq"
        #expect(DocumentWarmth.pin(for: req([ChatMessage(role: .user, content: ex)]), chatID: "c") == nil)
    }

    @Test func pinSurvivesTheWire() throws {
        var r = req([ChatMessage(role: .user, content: doc)])
        r.prefixPin = DocumentWarmth.pin(for: r, chatID: "c")
        let back = try JSONDecoder().decode(ChatRequest.self, from: JSONEncoder().encode(r))
        #expect(back.prefixPin == r.prefixPin && back.prefixPin != nil)
        let plain = try JSONEncoder().encode(req([]))
        #expect(!String(decoding: plain, as: UTF8.self).contains("prefixPin"))
    }
}
