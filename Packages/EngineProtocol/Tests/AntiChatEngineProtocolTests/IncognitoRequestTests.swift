// M1.T20: `ChatRequest.incognito` crosses XPC; absent on the wire unless true (older peers and fixtures unchanged).
import Foundation
import Testing
@testable import AntiChatEngineProtocol

@Suite struct IncognitoRequestTests {
    let base = ChatRequest(modelSlot: .scripted("s"), messages: [.message(ChatMessage(role: .user, content: "hi"))],
                           toolChoice: .auto, grammar: "root ::= \"x\"", turnContext: "Now: 09:30")

    @Test func roundTripsAndDefaultsToFalse() throws {
        var r = base
        r.incognito = true
        let back = try JSONDecoder().decode(ChatRequest.self, from: try JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.incognito)
        let plain = try JSONEncoder().encode(base)
        #expect(!String(decoding: plain, as: UTF8.self).contains("incognito"))
        #expect(try JSONDecoder().decode(ChatRequest.self, from: plain) == base)
    }
}
