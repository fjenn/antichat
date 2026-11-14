// M2.T06 AT-222 part 1 (R-222 AC1): every fixtures/hardware/*.json × pack × mode selects what
// fixtures/hardware/expected-selection.json says (model-matrix §2.1/§9.3, incl. T1 < 120 GB/s → chat-4b / evil-4b);
// a `disable`-revoked id is never selected; embed on every tier (AT-295). Writes build/at/AT-222/selection-matrix.csv.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct ModelSelectorTierMatrixTests {
    struct Expected: Decodable {
        struct Pair: Decodable { var normal: String?; var evil: String? }
        var cell: String; var chat: Pair; var ctx: Int; var chat_fast: String; var title: String
        var embed: String; var rerank: String?; var voice: Pair; var photo: Pair; var video: Pair
    }

    func expected() throws -> [String: Expected] {
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: SelectorFixtures.hardwareDir.appending(path: "expected-selection.json"))) as! [String: Any]
        raw["_doc"] = nil
        return try JSONDecoder().decode([String: Expected].self, from: JSONSerialization.data(withJSONObject: raw))
    }

    @Test func everyFixtureMatchesTheMatrix() throws {
        let catalog = try SelectorFixtures.baseline()
        let selector = ModelSelector(catalog: catalog)
        let want = try expected()
        #expect(Set(want.keys) == Set(SelectorFixtures.names))
        var csv = ["fixture,cell,speed_class,pack,mode,role,model,ctx,fit,reason,expected,match"]
        var mismatches = 0
        for name in SelectorFixtures.names {
            let p = try SelectorFixtures.profile(name)
            let s = selector.select(profile: p, modes: [.normal, .evil])
            let w = try #require(want[name], "\(name)")
            var checks: [(ModelPack, ModelMode, String, String?)] = []
            for mode in ModelMode.allCases {
                checks.append((.chat, mode, "chat", mode == .normal ? w.chat.normal : w.chat.evil))
                checks.append((.voice, mode, "voice", mode == .normal ? w.voice.normal : w.voice.evil))
                checks.append((.photo, mode, "photo", mode == .normal ? w.photo.normal : w.photo.evil))
                checks.append((.video, mode, "video", mode == .normal ? w.video.normal : w.video.evil))
            }
            checks += [(.chat, .normal, "chat_fast", w.chat_fast), (.chat, .normal, "title", w.title),
                       (.chat, .normal, "embed", w.embed), (.chat, .normal, "rerank", w.rerank)]
            #expect(s.cellKey == w.cell, "\(name)")
            for (pack, mode, role, model) in checks {
                let slot = s.slot(pack, mode, role: role)
                let ok = slot?.modelID == model
                if !ok { mismatches += 1 }
                #expect(ok, "\(name) \(pack.rawValue)/\(mode.rawValue)/\(role): \(slot?.modelID ?? "nil") ≠ \(model ?? "nil")")
                #expect(model != nil || slot?.reason != nil, "\(name) \(role): an empty slot carries a reason")
                csv.append([name, s.cellKey, s.speedClass.rawValue, pack.rawValue, mode.rawValue, role, slot?.modelID ?? "",
                            slot?.ctx.map(String.init) ?? "", slot?.fit?.rawValue ?? "", slot?.reason ?? "", model ?? "", ok ? "1" : "0"].joined(separator: ","))
            }
            #expect(s.slot(.chat, .normal, role: "chat")?.ctx == w.ctx, "\(name) ctx")
            #expect(s.slot(.chat, .normal, role: "chat")?.notes.contains(.contextLowered) == false, "\(name)")
        }
        #expect(mismatches == 0)
        try SelectorFixtures.write(csv.joined(separator: "\n") + "\n", to: "build/at/AT-222/selection-matrix.csv")
    }

    @Test func testRevokedSkipped() throws {
        let revoked = try CatalogFixtures.catalog("catalog-revoked")
        let selector = ModelSelector(catalog: revoked)
        for name in SelectorFixtures.names {
            let s = selector.select(profile: try SelectorFixtures.profile(name), modes: [.normal, .evil])
            #expect(!s.slots.contains { $0.modelID == "chat-9b-q4" || $0.installIDs.contains("chat-9b-q4") }, "\(name)")
        }
        // T1 ≥ 120 GB/s and T2-24 picked chat-9b-q4: the cell's step-down replaces it, with the withdrawal notice.
        for name in ["t1-m3pro-18", "t2-m4-24"] {
            let chat = selector.select(profile: try SelectorFixtures.profile(name)).slot(.chat, .normal, role: "chat")
            #expect(chat?.modelID == "chat-4b", "\(name)")
            #expect(chat?.notes.contains(.revokedReplaced) == true, "\(name)")
        }
        // `warn` keeps the model selectable.
        #expect(selector.select(profile: try SelectorFixtures.profile("t1-m1-16")).slot(.chat, .normal, role: "chat")?.modelID == "chat-4b")
    }

    /// AT-295 leg: the embedding model is selected on every tier.
    @Test func testEmbedEveryTier() throws {
        let selector = ModelSelector(catalog: try SelectorFixtures.baseline())
        for name in SelectorFixtures.names {
            let embed = selector.select(profile: try SelectorFixtures.profile(name)).slot(.chat, .normal, role: "embed")
            #expect(embed?.modelID == "embed", "\(name)")
            #expect(embed?.fit != .tooLarge, "\(name)")
        }
    }

    @Test func selectorIsDeterministic() throws {
        let selector = ModelSelector(catalog: try SelectorFixtures.baseline())
        let p = try SelectorFixtures.profile("t2-m3max-36")
        #expect(selector.select(profile: p, modes: [.normal, .evil]) == selector.select(profile: p, modes: [.normal, .evil]))
    }

    @Test func overridesWinWhenTheyFit() throws {
        let selector = ModelSelector(catalog: try SelectorFixtures.baseline())
        let t1 = try SelectorFixtures.profile("t1-m3pro-18")
        let small = selector.select(profile: t1, overrides: [ModelOverride(pack: .chat, mode: .normal, modelID: "chat-2b")])
        #expect(small.slot(.chat, .normal, role: "chat")?.modelID == "chat-2b")
        #expect(small.slot(.chat, .normal, role: "chat")?.notes == [.overrideUsed])
        let huge = ModelOverride(pack: .chat, mode: .normal, modelID: "chat-122b")
        #expect(selector.select(profile: t1, overrides: [huge]).slot(.chat, .normal, role: "chat")?.modelID == "chat-9b-q4")
        #expect(selector.select(profile: t1, overrides: [huge], allowOverBudget: true).slot(.chat, .normal, role: "chat")?.modelID == "chat-122b")
        let unknown = ModelOverride(pack: .chat, mode: .normal, modelID: "gone-model")
        #expect(selector.select(profile: t1, overrides: [unknown]).slot(.chat, .normal, role: "chat")?.notes.contains(.overrideIgnored) == true)
        let evilFast = ModelOverride(pack: .chat, mode: .evil, modelID: "chat-0.8b")
        #expect(selector.select(profile: t1, modes: [.evil], overrides: [evilFast]).slot(.chat, .evil, role: "chat")?.modelID == "evil-9b")
    }
}
