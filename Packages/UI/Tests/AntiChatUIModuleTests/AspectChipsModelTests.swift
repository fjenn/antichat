// M4.T07 step 2 (R-030 AC2): the aspect chips beside Create image — shown only with that chip, one pick at a time,
// stored with the chat's chips (`aspect:<ratio>` in tools_json: per chat, survives a relaunch), cleared by picking it
// again or by removing Create image. The five chips map to the five `create_image` ratios.
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct AspectChipsModelTests {
    func chips() -> ToolChipsModel {
        let c = ComposerMenuContext(installedPacks: ["chat", "photo"], activeModelKey: "chat-9b-q4")
        let m = ToolChipsModel()
        m.available = SlashCommandRegistry.menuItems(c)
        return m
    }

    @Test func aspectsShowWithCreateImageAndPersist() throws {
        let m = chips()
        var saved: [String?] = []
        m.onChange = { saved.append($0) }
        #expect(!m.showsAspects)
        let image = try #require(m.available.first { $0.id == "image" })
        #expect(m.add(image))
        #expect(m.showsAspects && m.aspect == nil)
        m.setAspect("9:16")
        #expect(m.aspect == "9:16" && m.chips.map(\.id) == ["image"], "the aspect is stored, not drawn as a tool chip")
        #expect(saved.last == #"["image","aspect:9:16"]"#)
        m.setAspect("16:9")
        #expect(m.aspect == "16:9" && m.ids.filter { $0.hasPrefix("aspect:") }.count == 1)
        m.setAspect("16:9")
        #expect(m.aspect == nil, "picking the same chip again clears it")
        m.setAspect("2:3")
        let reloaded = chips()
        reloaded.load(toolsJSON: saved.last ?? nil)
        #expect(reloaded.aspect == "2:3" && reloaded.showsAspects, "per chat, across relaunches")
        reloaded.remove("image")
        #expect(reloaded.aspect == nil && !reloaded.showsAspects)
    }

    /// Q-015 r4: a send carries the aspect pick with Create image (it is not a drawn chip, and `chips` dropped it), and
    /// the turn reads it back (`TurnController.imageAspect`).
    @Test func aSendCarriesTheAspect() throws {
        let m = chips()
        #expect(m.add(try #require(m.available.first { $0.id == "image" })))
        #expect(m.turnIDs == ["image"])
        m.setAspect("1:1")
        #expect(m.turnIDs == ["image", "aspect:1:1"])
        #expect(TurnController.imageAspect(chips: m.turnIDs) == "1:1")
        m.remove("image")
        #expect(m.turnIDs.isEmpty)
    }

    @Test func chipsMapToTheToolRatios() {
        #expect(Set(AspectChoice.all.map(\.ratio)) == Set(CreateImageTool.aspects))
        #expect(AspectChoice.all.map(\.copyKey) == ["img.aspect.square", "img.aspect.portrait", "img.aspect.landscape",
                                                     "img.aspect.story", "img.aspect.wide"])
        #expect(abs(AspectChoice.all[1].value - 2.0 / 3.0) < 0.001)
    }
}
