// AT-268 in process (R-268 AC1–AC3) — M7.T14. The XCUITest legs (ToolsPageUITests: testEveryToolListedWithSwitch,
// testConnectorToolPermissions, testPlusMenuPerChatDoesNotChangeGlobal, testToolAccessWarnsOnT0toT2) are written but
// pending Q-015; these cover the same behaviour on the models the views bind to:
//   c1: the Tools page lists Web search, Create files, Analyse data, Memory with switches (Settings rows + copy;
//       creating images and video is the Images and Video packs' switches, which turn the tool on), connector tools keep Always allow / Ask / Block (ConnectionDetail, M7.T06);
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
        #expect(ToolsPageModel.listed == [.web, .files, .code, .memory])
        let titles = ToolsPageModel.listed.map { CopyText(CopyKey($0.copyKey)).string }
        #expect(titles == ["Web search", "Create files", "Analyse data", "Memory"])
        // One switch per feature: no row repeats a pack's switch, and no line on the page says Python or sandbox.
        #expect(SettingsRegistry.row("toolImage") == nil && SettingsRegistry.row("toolVideo") == nil)
        for g in ToolsPageModel.listed {
            let note = SettingsRegistry.row(ToolsPageModel.rowID(g))?.note?.string() ?? ""
            #expect(!note.isEmpty && !note.localizedCaseInsensitiveContains("python") && !note.localizedCaseInsensitiveContains("sandbox"), "\(g)")
        }
        for g in ToolsPageModel.listed { #expect(SettingsRegistry.row(ToolsPageModel.rowID(g)) != nil, "\(g)") }
        for g in ToolsPageModel.rows {
            #expect(SettingsRegistry.row(ToolsPageModel.rowID(g)) != nil, "\(g)")
            #expect(m.isOn(g) == g.defaultOn)
        }
        #expect(SettingsRegistry.row("webSearch") != nil && SettingsRegistry.row("toolAccess") != nil)
        m.set(.memory, false)
        #expect(!m.isOn(.memory) && d.object(forKey: "toolMemory") as? Bool == false && !s.isOn(.memory))
        m.set(.code, true)  // M6.T19's `runCodeEnabled` (FileToolsSettingsRows draws that row)
        #expect(s.isOn(.code) && d.object(forKey: "runCodeEnabled") as? Bool == true)
    }

    /// The pack's switch is the tool's switch: turning the pack on turns a tool on that an earlier build's
    /// "Create image" / "Create video" row had turned off; a pack that is off changes nothing.
    @Test func aPackThatIsOnTurnsItsToolOn() {
        let (s, d) = Self.switches()
        s.setOn(.image, false)
        s.setOn(.video, false)
        let packs = PackManagementModel(defaults: UserDefaults.inMemory())
        packs.toolSwitches = s
        packs.syncTools()
        #expect(!s.isOn(.image) && !s.isOn(.video), "both packs are off")
        packs.enabled.insert(.photo)
        packs.syncTools()
        #expect(s.isOn(.image) && d.object(forKey: "toolImage") as? Bool == true)
        #expect(!s.isOn(.video), "Video is still off")
    }

    @Test func connectorToolsKeepThreePermissions() {
        #expect(["conn.perm.always", "conn.perm.ask", "conn.perm.block"].map { CopyText(CopyKey($0)).string }
                == ["Always allow", "Ask", "Block"])
    }

    // MARK: c2

    /// The + menu has no Tools row (the switches live in Settings › Capabilities); a chat's stored markers still count.
    @Test func plusMenuHasNoToolsRowAndStoredMarkersStillCount() {
        let (s, _) = Self.switches()
        let ctx = ComposerMenuContext(installedPacks: ["chat", "photo"], activeModelKey: "chat-9b-q4")
        #expect(!SlashCommandRegistry.addItems(ctx).contains { $0.id == "tools" })
        let chat = ToolChipsModel()
        chat.load(toolsJSON: #"["tool.off:memory"]"#)
        #expect(!s.isOn(.memory, chatToolIDs: chat.ids))
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
