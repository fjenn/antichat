// M7.T12 AT-082 UI-model legs (in-process; the XCUITest legs are pending Q-015): Settings → Skills lists the
// starters with their switches and source, Add stages a review candidate (nothing installed until Install), Delete
// and Export work, "needs Web search (off)" is worded from the deck; the + menu's Skills row opens the per-chat
// switches, a "/" pick makes a `skill:<name>` chip, and the per-chat switch writes only markers.
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.serialized, .isolatedSettings) struct SkillsModelTests {
    func library() throws -> (SkillsLibrary, SkillStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-ui-model-\(UUID().uuidString)", isDirectory: true)
        let store = SkillStore(root: dir, database: try AppDatabase.inMemory())
        try StarterSkills.installIfNeeded(into: store)
        let lib = SkillsLibrary()
        lib.store = { store }
        lib.reload()
        return (lib, store, dir)
    }

    @Test func listReviewInstallDeleteExport() throws {
        let (lib, store, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(lib.skills.map(\.name) == ["email-polish", "meeting-notes", "recipe-scaler", "study-flashcards", "trip-planner"])
        #expect(lib.skills.first { $0.name == "email-polish" }?.record.enabled == true)
        // Add: review first.
        let src = dir.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString)/web-helper")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let md = "---\nname: web-helper\ndescription: Looks things up.\nallowed-tools: web_search\n---\nSearch first."
        try md.write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        lib.beginImport(src)
        let c = try #require(lib.reviewing)
        #expect(c.markdown == md && c.canInstall)
        #expect(store.skill(named: "web-helper") == nil, "nothing installed before Install")
        lib.install()
        #expect(lib.reviewing == nil)
        let helper = try #require(lib.skills.first { $0.name == "web-helper" })
        #expect(helper.record.trust == .user)
        #expect(SkillsLibrary.needs(helper, webSearch: .switchedOff).map(\.string) == ["needs Web search (off)"])
        #expect(SkillsLibrary.needs(helper, webSearch: .offlineOnly).map(\.string) == ["needs Web search (offline)"])
        // A refused source says why (skills.invalid), and no sheet opens.
        lib.beginImport(src.appendingPathComponent("nope.zip"))
        #expect(lib.reviewing == nil)
        #expect(lib.error?.hasPrefix("This skill isn't valid:") == true)
        // Delete.
        lib.delete("web-helper")
        #expect(!lib.skills.contains { $0.name == "web-helper" })
        // Switches.
        lib.setApplyAll("meeting-notes", true)
        lib.setEnabled("email-polish", false)
        #expect(lib.skills.first { $0.name == "meeting-notes" }?.record.applyAll == true)
        #expect(lib.skills.first { $0.name == "email-polish" }?.record.enabled == false)
    }

    @Test func plusMenuSkillsRowAndSlashChip() throws {
        let (_, store, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let menus = ComposerMenus()
        var ctx = ComposerMenuContext(activeModelKey: "chat-9b-q4")
        ctx.loadSkills(store)
        menus.context = ctx
        let row = try #require(menus.addItems.first { $0.id == "skills" })
        #expect(ComposerMenus.title(row) == "Skills")
        menus.pickAdd(row)
        #expect(menus.isSkillsMenuOpen && menus.chips.ids.isEmpty, "opens the per-chat switches, no chip")
        let skill = try #require(menus.menuItems.first { $0.id == "skill:email-polish" })
        #expect(ComposerMenus.title(skill) == "email-polish")
        menus.pickInline(skill)
        #expect(menus.chips.ids == ["skill:email-polish"])
        #expect(menus.chips.chips.map(\.id) == ["skill:email-polish"], "the chip is shown")
    }

    @Test func perChatSwitchWritesMarkersOnly() throws {
        let (_, store, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chips = ToolChipsModel()
        var saved: [String?] = []
        chips.onChange = { saved.append($0) }
        let notes = try #require(store.skill(named: "meeting-notes"))
        let trip = try #require(store.skill(named: "trip-planner"))
        #expect(SkillTools.isOn(notes, in: chips.ids) && !SkillTools.isOn(trip, in: chips.ids))
        chips.addMarker(SkillTools.offMarker("meeting-notes"))
        chips.addMarker(SkillTools.onMarker("trip-planner"))
        #expect(!SkillTools.isOn(notes, in: chips.ids) && SkillTools.isOn(trip, in: chips.ids))
        #expect(saved.last == #"["skill.off:meeting-notes","skill.on:trip-planner"]"#)
        #expect(try #require(store.skill(named: "meeting-notes")).record.enabled, "the global switch is untouched")
        #expect(chips.chips.isEmpty, "markers are not chips")
    }

    @Test func settingsRowsReplaceThePlaceholder() {
        #expect(SettingsRegistry.row("skills.later") == nil)
        #expect(SettingsRegistry.row("skills")?.enabled == true)
        #expect(SettingsRegistry.row("addSkill")?.label.string() == "Add skill")
    }
}
