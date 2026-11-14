// ToolChipsModelTests (M1.T17; AT-013 legs 1 and 3, unit part): the + list per pack state (AC1 wording), D-023 (no
// tool entries or chips for the starter), sticky chips (kept after a send, `chat.tools_json` round trip, × saves),
// and chip persistence through ChatRepository.
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ToolChipsModelTests {
    private static let tools: [ComposerMenuContext.Tool] = [.init(name: "echo", description: "Repeat the given text back.")]

    private func ids(_ c: ComposerMenuContext) -> [String] { SlashCommandRegistry.addItems(c).map(\.id) }
    private func state(_ id: String, _ c: ComposerMenuContext) -> ComposerMenuItem.State? {
        SlashCommandRegistry.addItems(c).first { $0.id == id }?.state
    }

    // MARK: AC1: the + list

    @Test func chatOnlyListsDisabledPacksAndHidesWebAndConnections() {
        let c = ComposerMenuContext(activeModelKey: "chat-9b-q4", tools: Self.tools)
        #expect(ids(c) == ["files", "image", "video", "tools", "project"])  // M7.T14: Tools › for a tool-taking model
        #expect(state("files", c) == .enabled)
        #expect(state("image", c) == .needsPack("photo"))
        #expect(state("video", c) == .needsPack("video"))
        #expect(ComposerMenus.reason(.needsPack("photo"))?.string == "Install Photo to use this")
        #expect(ComposerMenus.reason(.needsPack("video"))?.string == "Install Video to use this")
        #expect(state("project", c) == .notYet)
    }

    @Test func installedButOffSaysEnableInSettingsAndStaysListed() {
        let c = ComposerMenuContext(installedPacks: ["chat", "photo", "video"], disabledPacks: ["photo"],
                                    activeModelKey: "chat-9b-q4")
        #expect(ids(c).contains("image"))
        #expect(state("image", c) == .needsEnable("photo"))
        #expect(ComposerMenus.reason(.needsEnable("photo"))?.string == "Enable in Settings")
        #expect(state("video", c) == .enabled)
        let menus = ComposerMenus()
        menus.context = c
        var opened = 0
        menus.openSettings = { opened += 1 }
        menus.pickAdd(menus.addItems.first { $0.id == "image" }!)
        #expect(opened == 1, "clicking it opens Settings → Capabilities")
        #expect(menus.chips.ids.isEmpty)
    }

    @Test func fullFakeSetShowsWebAndConnectionsEnabled() {
        let c = ComposerMenuContext(installedPacks: ["chat", "photo", "video"], webSearchEnabled: true,
                                    connectionsEnabled: true, activeModelKey: "chat-9b-q4", tools: Self.tools)
        #expect(ids(c) == ["files", "image", "video", "web", "connections", "tools", "project"])  // M7.T14: Tools ›
        #expect(state("web", c) == .enabled)
        #expect(state("connections", c) == .enabled)
        #expect(SlashCommandRegistry.menuItems(c).map(\.id).last == "tool:echo")
    }

    @Test func starterHasNoToolEntriesOrChips() {  // D-023 (a)
        let c = ComposerMenuContext(installedPacks: ["chat", "photo", "video"], webSearchEnabled: true,
                                    connectionsEnabled: true, activeModelKey: "chat-0.8b", tools: Self.tools)
        let all = SlashCommandRegistry.menuItems(c).map(\.id)
        #expect(!all.contains("web") && !all.contains("connections") && !all.contains("tool:echo"))
        #expect(all == ["files", "image", "video", "project"])
        let chips = ToolChipsModel()
        chips.load(toolsJSON: #"["tool:echo","web"]"#)
        chips.available = SlashCommandRegistry.menuItems(c)
        #expect(chips.chips.isEmpty, "stored chips are not shown while the starter is active")
        #expect(chips.ids == ["tool:echo", "web"], "…and come back with a model that takes tools")
    }

    // MARK: AC3: sticky chips

    private func model(_ key: String = "chat-9b-q4") -> ComposerModel {
        let m = ComposerModel()
        m.menus.context = ComposerMenuContext(webSearchEnabled: true, activeModelKey: key, tools: Self.tools)
        return m
    }

    @Test func pickedChipStaysAfterSendAndTravelsWithTheSubmission() {
        let m = model()
        var saved: [String?] = []
        m.menus.chips.onChange = { saved.append($0) }
        m.menus.pickAdd(m.menus.addItems.first { $0.id == "web" }!)
        #expect(m.menus.chips.chips.map(\.id) == ["web"])
        var got: ComposerSubmission?
        m.onSend = { got = $0 }
        m.text = "news today"
        #expect(m.send())
        #expect(got?.tools == ["web"])
        #expect(m.menus.chips.chips.map(\.id) == ["web"], "sticky: still there for the next message")
        m.turnFinished()
        m.menus.chips.remove("web")
        #expect(m.menus.chips.chips.isEmpty)
        #expect(saved == [#"["web"]"#, nil], "every pick and × is saved")
    }

    @Test func pickingTwiceDoesNotDuplicate() {
        let m = model()
        let web = m.menus.addItems.first { $0.id == "web" }!
        m.menus.pickAdd(web)
        m.menus.pickAdd(web)
        #expect(m.menus.chips.ids == ["web"])
        #expect(!m.menus.chips.add(m.menus.addItems.first { $0.id == "files" }!), "Add photos & files makes no chip")
    }

    @Test func filesPickOpensThePickerAndAddsTilesNotSendable() {
        let m = model()
        m.menus.chooseFiles = { [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/a.pdf")] }
        m.menus.pickAdd(m.menus.addItems.first { $0.id == "files" }!)
        #expect(m.attachments.map(\.fileURL?.lastPathComponent) == ["a.pdf"])
        #expect(!m.canSend, "without a window's intake the tile is not read, so not sent (M6.T01)")
        #expect(m.usesBottomRow)
    }

    @Test func toolsJSONRoundTrip() {
        #expect(ToolChipsModel.encode([]) == nil)
        #expect(ToolChipsModel.decode(ToolChipsModel.encode(["web", "tool:echo"])) == ["web", "tool:echo"])
        #expect(ToolChipsModel.decode("not json") == [])
        #expect(ToolChipsModel.decode(#"["a","a",""]"#) == ["a"])
        #expect(ToolChipsModel.decode(nil) == [])
    }

    @Test func chipsPersistPerChatInToolsJSON() throws {
        let db = try AppDatabase.inMemory()
        let repo = ChatRepository(db)
        let chat = try repo.create(title: "t")
        #expect(try repo.toolsJSON(chat.id) == nil)
        let before = try repo.chat(chat.id)?.updatedAt
        #expect(try repo.setToolsJSON(chat.id, #"["web"]"#))
        #expect(try repo.toolsJSON(chat.id) == #"["web"]"#)
        #expect(try repo.chat(chat.id)?.updatedAt == before, "not an edit: the sidebar order is kept")
        #expect(try repo.setToolsJSON(chat.id, nil))
        #expect(try repo.toolsJSON(chat.id) == nil)
        #expect(try !repo.setToolsJSON("missing", "[]"))
    }
}
