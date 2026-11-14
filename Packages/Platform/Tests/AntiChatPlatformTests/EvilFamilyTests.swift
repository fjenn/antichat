// M2.T06 AT-239 (R-239 AC1): on every tier the Evil chat pick shares `family` and `chat_template` with the Normal pick
// of the same cell (model-matrix §9.3: same-base Qwen3.5 / Qwen3.6 / Gemma 4 builds), or the cell records
// `evil_family_reason`; Evil never uses or steps down to `chat_fast` (R-227); the selected Evil model follows the
// same rule after the selector's speed guard (T1 < 120 GB/s: chat-4b ↔ evil-4b).
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct EvilFamilyTests {
    @Test func everyCellSharesFamilyAndTemplate() throws {
        let c = try SelectorFixtures.baseline()
        for (key, classes) in c.assignments {
            for (sc, cell) in classes {
                let at = "\(key)/\(sc.rawValue)"
                let n = try #require(cell.chat.normal, "\(at)"), e = try #require(cell.chat.evil, "\(at)")
                let nm = try #require(c.models[n.model]), em = try #require(c.models[e.model])
                if cell.chat.evilFamilyReason == nil {
                    #expect(em.family != nil && em.family == nm.family, "\(at): \(e.model) vs \(n.model)")
                    #expect(em.chatTemplate == nm.chatTemplate, "\(at)")
                }
                if let ns = n.stepDown, let es = e.stepDown {
                    #expect(c.models[ns]?.family == c.models[es]?.family, "\(at) step-downs")
                }
                #expect(e.model != cell.chat.fastFirst && e.stepDown != cell.chat.fastFirst, "\(at)")
            }
        }
    }

    @Test func selectedEvilMatchesSelectedNormal() throws {
        let c = try SelectorFixtures.baseline()
        let selector = ModelSelector(catalog: c)
        for name in SelectorFixtures.names {
            let s = selector.select(profile: try SelectorFixtures.profile(name), modes: [.normal, .evil])
            let n = try #require(s.slot(.chat, .normal, role: "chat")?.modelID, "\(name)")
            let e = try #require(s.slot(.chat, .evil, role: "chat")?.modelID, "\(name)")
            #expect(c.models[n]?.family == c.models[e]?.family, "\(name): \(n) vs \(e)")
            #expect(c.models[n]?.chatTemplate == c.models[e]?.chatTemplate, "\(name)")
        }
    }

    @Test func evilPhotoVideoVoiceAreNormalIDs() throws {
        let selector = ModelSelector(catalog: try SelectorFixtures.baseline())
        for name in SelectorFixtures.names {
            let s = selector.select(profile: try SelectorFixtures.profile(name), modes: [.normal, .evil])
            for pack in [ModelPack.voice, .photo, .video] {
                #expect(s.slot(pack, .evil)?.modelID == s.slot(pack, .normal)?.modelID, "\(name) \(pack)")
            }
        }
    }
}
