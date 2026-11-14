// AT-268 in process (R-268 AC1–AC3) — M7.T14. The XCUITest legs (ToolsPageUITests: testEveryToolListedWithSwitch,
// testConnectorToolPermissions, testPlusMenuPerChatDoesNotChangeGlobal, testToolAccessWarnsOnT0toT2) are written but
// pending Q-015; these cover the same behaviour on the models the views bind to:
//   c1: the Tools page lists Web search, Create image, Create video, Create files, Run code, Memory with switches
//       (Settings rows + copy), connector tools keep Always allow / Ask / Block (ConnectionDetail, M7.T06);
//   c2: "+" lists the same tools with per-chat switches; a chat's change leaves the global store and another chat
//       unchanged; turning a tool off removes its chip; picking its row turns it back on;
//   c3: Tool access defaults to "Load tools when needed"; "Always offer all" warns on T1, not on T3.
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ToolsPageModelTests {
    static func switches() -> (ToolSwitches, UserDefaults) {
        let d = UserDefaults.inMemory()
        return (ToolSwitches(defaults: d), d)
    }

    // MARK: c1

    @Test func everyBuiltInToolIsListedWithASwitch() {
        let (s, d) = Self.switches()
        let m = ToolsPageModel(switches: s, tier: .t3)
        #expect(ToolsPageModel.listed == [.web, .image, .video, .files, .code, .memory])
        let titles = ToolsPageModel.listed.map { CopyText(CopyKey($0.copyKey)).string }
        #expect(titles == ["Web search", "Create image", "Create video", "Create files", "Run code for analysis", "Memory"])
        for g in ToolsPageModel.listed { #expect(SettingsRegistry.row(ToolsPageModel.rowID(g)) != nil, "\(g)") }
        for g in ToolsPageModel.rows {
            #expect(SettingsRegistry.row(ToolsPageModel.rowID(g)) != nil, "\(g)")
            #expect(m.isOn(g) == g.defaultOn)
        }
        #expect(SettingsRegistry.row("webSearch") != nil && SettingsRegistry.row("toolAccess") != nil)
        m.set(.image, false)
        #expect(!m.isOn(.image) && d.object(forKey: "toolImage") as? Bool == false && !s.isOn(.image))
        m.set(.code, true)  // M6.T19's `runCodeEnabled` (FileToolsSettingsRows draws that row)
        #expect(s.isOn(.code) && d.object(forKey: "runCodeEnabled") as? Bool == true)
    }

    @Test func connectorToolsKeepThreePermissions() {
        #expect(["conn.perm.always", "conn.perm.ask", "conn.perm.block"].map { CopyText(CopyKey($0)).string }
                == ["Always allow", "Ask", "Block"])
    }

    // MARK: c2

    @Test func plusMenuListsTheSameToolsAndPerChatNeverChangesGlobal() throws {
        let (s, d) = Self.switches()
        let ctx = ComposerMenuContext(installedPacks: ["chat", "photo"], activeModelKey: "chat-9b-q4")
        #expect(SlashCommandRegistry.addItems(ctx).contains { $0.id == "tools" })
        #expect(ComposerMenus.titleKey(.tools).string() == "Tools")
        let starter = ComposerMenuContext(activeModelKey: "chat-0.8b")
        #expect(!SlashCommandRegistry.addItems(starter).contains { $0.id == "tools" })  // D-023: no tools for the starter

        let chatA = ToolChipsModel(), chatB = ToolChipsModel()
        var saved: [String?] = []
        chatA.onChange = { saved.append($0) }
        chatA.add(ComposerMenuItem(id: "image", kind: .action(.image), group: .add, state: .enabled, symbol: "photo"))
        let before = d.dictionaryRepresentation().filter { $0.key.hasPrefix("tool") }
        for g in ToolGroup.allCases where g != .web {
            #expect(ToolsChatSwitches.isOn(g, chips: chatA, switches: s, web: .available) == s.isOn(g))
        }
        ToolsChatSwitches.set(.image, on: false, chips: chatA, switches: s)
        #expect(!ToolsChatSwitches.isOn(.image, chips: chatA, switches: s, web: .available))
        #expect(!chatA.contains("image"))  // its chip goes too
        #expect(chatA.ids.contains(ToolGroup.image.offMarker) && saved.last??.contains("tool.off:image") == true)
        ToolsChatSwitches.set(.code, on: true, chips: chatA, switches: s)
        #expect(chatA.ids.contains(ToolGroup.code.onMarker))
        // Global store and chat B unchanged.
        #expect(d.dictionaryRepresentation().filter { $0.key.hasPrefix("tool") }.keys.sorted() == before.keys.sorted())
        #expect(s.isOn(.image) && !s.isOn(.code))
        #expect(ToolsChatSwitches.isOn(.image, chips: chatB, switches: s, web: .available))
        // Back to the global state removes the marker; picking the row turns it on again.
        ToolsChatSwitches.set(.code, on: false, chips: chatA, switches: s)
        #expect(!chatA.ids.contains(ToolGroup.code.onMarker) && !chatA.ids.contains(ToolGroup.code.offMarker))
        chatA.add(ComposerMenuItem(id: "image", kind: .action(.image), group: .add, state: .enabled, symbol: "photo"))
        #expect(chatA.contains("image") && !chatA.ids.contains(ToolGroup.image.offMarker))
        // The markers survive the chat's `tools_json` round trip.
        let json = try #require(chatA.toolsJSON)
        chatB.load(toolsJSON: #"["tool.off:memory"]"#)
        #expect(!ToolsChatSwitches.isOn(.memory, chips: chatB, switches: s, web: .available))
        #expect(ToolChipsModel.decode(json).contains("image"))
    }

    @Test func webSearchSwitchIsOffAndDisabledWhileUnavailable() {
        let (s, _) = Self.switches()
        let chips = ToolChipsModel()
        #expect(ToolsChatSwitches.isOn(.web, chips: chips, switches: s, web: .available))
        for st in [WebSearchAvailability.State.offlineOnly, .noNetwork, .switchedOff] {
            #expect(!ToolsChatSwitches.isOn(.web, chips: chips, switches: s, web: st) && !ToolsChatSwitches.webPossible(st))
        }
        ToolsChatSwitches.set(.web, on: false, chips: chips, switches: s)
        #expect(chips.ids == [ToolGroup.web.offMarker])
        #expect(CopyText(CopyKey("net.offlineShort")).string == "Offline")
    }

    // MARK: c3

    @Test func toolAccessDefaultsToWhenNeededAndWarnsOnLowTiers() {
        let (s, d) = Self.switches()
        let t1 = ToolsPageModel(switches: s, tier: .t1), t3 = ToolsPageModel(switches: s, tier: .t3)
        #expect(t1.access == .whenNeeded && !t1.showsAllWarning)
        #expect(CopyText(CopyKey("set.tools.access.whenNeeded")).string == "Load tools when needed")
        t1.setAccess(.all)
        t3.reload()
        #expect(t1.showsAllWarning && !t3.showsAllWarning && t3.access == .all)
        #expect(d.string(forKey: "toolAccess") == "all")
        #expect(CopyText(CopyKey("set.tools.access.allWarn")).string == "This can make answers worse on this Mac.")
        for (tier, warns) in [(DeviceTier.t0, true), (.t1, true), (.t2, true), (.t3, false), (.t4, false)] {
            #expect(ToolAccess.warns(tier) == warns)
        }
    }
}
