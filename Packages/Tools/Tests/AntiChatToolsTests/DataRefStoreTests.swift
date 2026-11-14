// data_ref tolerance: a mistyped handle resolves only when it is an unambiguous unique prefix or near-match of one
// of the chat's `qr_` handles; ambiguous, hallucinated or other-chat handles stay unresolved.
//   make test-unit FILTER=DataRefStoreTests
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct DataRefStoreTests {
    static func ref(_ id: String) -> DataRef {
        DataRef(id: id, sql: "SELECT 1", columns: ["a"], types: ["BIGINT"], rows: [["1"]], truncated: false)
    }

    @Test func unambiguousMistypesResolve() {
        let s = DataRefStore(), chat = "c1"
        let a = "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56ef", b = "qr_9d8e7f60-1a2b-4c3d-8e9f-a0b1c2d3e4f5"
        s.put(chatID: chat, Self.ref(a)); s.put(chatID: chat, Self.ref(b))
        #expect(s.get(chatID: chat, id: a)?.id == a)
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e")?.id == a)  // truncated: unique prefix
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56e")?.id == a)  // one char dropped
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd65ef")?.id == a)  // two swapped
        #expect(s.get(chatID: chat, id: "3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56ef")?.id == a)  // prefix missing
        #expect(s.get(chatID: chat, id: " \"QR_9D8E7F60-1A2B-4C3D-8E9F-A0B1C2D3E4F5\" ")?.id == b)  // case / quotes
    }

    @Test func ambiguousOrUnknownHandlesStayRejected() {
        let s = DataRefStore(), chat = "c2"
        let a = "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56ef", b = "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56aa"
        s.put(chatID: chat, Self.ref(a)); s.put(chatID: chat, Self.ref(b))
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e") == nil)  // prefix of both
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56ea") == nil)  // 1 edit from each
        #expect(s.get(chatID: chat, id: "qr_3f2a9c1e-7b4d-4e8a-9c0f-12ab34cd56e")?.id == a)  // still a unique prefix
        #expect(s.get(chatID: chat, id: "qr_00000000-0000-4000-8000-000000000000") == nil)  // hallucinated
        #expect(s.get(chatID: chat, id: "qr_3f2a") == nil)  // too short to be a prefix, far from both
        #expect(s.get(chatID: chat, id: "qr_9") == nil)
        #expect(s.get(chatID: chat, id: "") == nil)
        #expect(s.get(chatID: "other-chat", id: a) == nil)  // another chat's handle
        let single = DataRefStore()
        single.put(chatID: chat, Self.ref(a))
        #expect(single.get(chatID: chat, id: "qr_3f2a") == nil)  // short garbage never binds, even to the only one
    }
}
