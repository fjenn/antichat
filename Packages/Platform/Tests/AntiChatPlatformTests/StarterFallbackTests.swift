// M2.T06 AT-298 (R-298): the starter (`chat_fast` = chat-0.8b) stays selected and internal on T0–T2 after the tier
// model lands; titles resolve to it; with the external Models drive missing Normal chat routes to it with
// `model.drive.missing`; Evil gets no stand-in (R-227). Runtime fallback: AT-206 (T13); Advanced-only removal: AT-202 (T21).
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct StarterFallbackTests {
    let selector = ModelSelector(catalog: try! SelectorFixtures.baseline())

    @Test func starterKeptInternalOnT0toT2() throws {
        for name in SelectorFixtures.names {
            let p = try SelectorFixtures.profile(name)
            let s = selector.select(profile: p, modes: [.normal, .evil])
            let fast = try #require(s.chatFast, "\(name)")
            #expect(fast.modelID == "chat-0.8b", "\(name)")
            #expect(fast.keepInternal == (p.tier <= .T2), "\(name)")
            #expect(s.installIDs(packs: [.chat], modes: [.normal]).contains("chat-0.8b"), "\(name): installed with the tier model")
            #expect(s.slot(.chat, .normal, role: "chat")?.modelID != "chat-0.8b", "\(name): the tier model is the default")
        }
    }

    @Test func titlesUseTheStarter() throws {
        for name in SelectorFixtures.names where try SelectorFixtures.profile(name).tier <= .T2 {
            #expect(selector.select(profile: try SelectorFixtures.profile(name)).title?.modelID == "chat-0.8b", "\(name)")
        }
    }

    @Test func driveMissingRoutesToStarter() throws {
        for name in ["t0-m1-8", "t1-m3pro-18", "t2-m3max-36"] {
            let s = selector.select(profile: try SelectorFixtures.profile(name), modes: [.normal, .evil])
            #expect(s.chatRoute(mode: .normal, modelsDriveConnected: true).noticeKey == nil)
            #expect(s.chatRoute(mode: .normal, modelsDriveConnected: false) == .init(modelID: "chat-0.8b", noticeKey: "model.drive.missing"), "\(name)")
            #expect(s.chatRoute(mode: .evil, modelsDriveConnected: false) == .init(modelID: nil, noticeKey: "model.drive.missing"), "\(name)")
        }
    }
}
