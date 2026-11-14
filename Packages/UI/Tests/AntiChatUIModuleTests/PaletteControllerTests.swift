// AT-012 (M1.T11, R-012) controller legs: tabs, providers, ranking order into the vendored view, activation,
// Tab = ask in a new chat, Escape, Switch chat, and the Liked filter (AT-005 leg 4's ⌘K half). The window-level
// legs (⌘K opens it, keys, footer on screen, 10k latency through the UI) run in the in-process probe
// (`-PaletteProbe`, tools/at/at-012-probe.sh) and in J09PaletteTests once XCUITest runs (Q-015).
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct PaletteControllerTests {
    struct World {
        let env: ChatEnvironment
        let state: WindowState
        let palette: PaletteController
        var chats: [String: String] = [:]
        var replies: [String: String] = [:]
    }

    private func make() throws -> World {
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok"}"#)),
                                  slot: { .scripted("inline") })
        let service = ChatListService(environment: env)
        let state = WindowState(service: service, seed: 1)
        var w = World(env: env, state: state, palette: PaletteController())
        for (name, title, user, reply) in [
            ("pasta", "Pasta night", "What should I cook?", "A simple tomato sauce."),
            ("garden", "Garden", "Soil tips?", "Compost helps. The zebracorn is the search fixture."),
            ("tax", "Tax forms", "Deadline?", "April, and pasta is not deductible."),
        ] {
            let c = try service.create(title: title)
            try service.appendUserMessage(c.id, text: user)
            w.replies[name] = try service.appendAssistantMessage(c.id, text: reply).id
            w.chats[name] = c.id
        }
        w.palette.attach(state)
        return w
    }

    /// Waits for the next applied result set (chat search finished).
    private func settle(_ p: PaletteController, after generation: Int) async {
        for _ in 0..<6000 where p.resultGeneration <= generation {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func type(_ q: String, _ p: PaletteController) async {
        let g = p.resultGeneration
        p.queryDidChange(q)
        await settle(p, after: g)
    }

    private func present(_ p: PaletteController, tab: PaletteTab = .all) async {
        let g = p.resultGeneration
        p.present(tab: tab)
        await settle(p, after: g)
    }

    // MARK: AC1 tabs + search

    @Test func emptyQueryShowsRecentsThenActions() async throws {
        let w = try make()
        await present(w.palette)
        #expect(w.palette.isPresented)
        #expect(PaletteTab.allCases.map { $0.title.string() } == ["All", "Actions", "Chats", "Settings"])
        let groups = w.palette.items.map(\.group)
        #expect(groups.prefix(3) == [.chats, .chats, .chats])
        #expect(groups.dropFirst(3).allSatisfy { $0 == .actions })
        // The vendored view gets the same rows in the same order, grouped by category on All.
        #expect(w.palette.candidates.map(\.id) == w.palette.items.map(\.id))
        #expect(w.palette.candidates.first?.category == "Chats")
        // VQ-M10 S-18: the Settings pages read under their own "Settings" header, after the actions.
        let headers = w.palette.candidates.compactMap(\.category)
        #expect(headers.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } } == ["Chats", "Actions", "Settings"])
        let pages = w.palette.candidates.filter { $0.id.hasPrefix("action.settings.") }
        #expect(pages.count == SettingsSection.allCases.count && pages.allSatisfy { $0.category == "Settings" })
    }

    @Test func bodyOnlyTokenFindsItsChat() async throws {
        let w = try make()
        await present(w.palette)
        await type("zebracorn", w.palette)
        let chats = w.palette.items.filter { $0.group == .chats }
        #expect(chats.map(\.id) == ["chat.\(w.chats["garden"]!)"])
        let excerpt = try #require(chats.first?.excerpt)
        #expect(excerpt.contains { $0.isMatch && $0.text.lowercased() == "zebracorn" })
    }

    /// Q-015 r7 (J09): the recents never stand in for a query's matches while its search is pending (J09 counted the
    /// 8 recents under "zebracorn"; Return in that window opened a recent chat).
    @Test func typingDropsTheRecentsBeforeTheSearchReturns() async throws {
        let w = try make()
        await present(w.palette)
        #expect(w.palette.items.contains { $0.group == .chats })
        let g = w.palette.resultGeneration
        w.palette.queryDidChange("zebracorn")
        #expect(!w.palette.items.contains { $0.group == .chats })  // synchronously, before the debounced search
        await settle(w.palette, after: g)
        #expect(w.palette.items.filter { $0.group == .chats }.map(\.id) == ["chat.\(w.chats["garden"]!)"])
        // A refined query keeps the previous query's matches until its own arrive.
        w.palette.queryDidChange("zebracorn ")
        #expect(w.palette.items.filter { $0.group == .chats }.map(\.id) == ["chat.\(w.chats["garden"]!)"])
    }

    @Test func titleWordFindsItsChatFirst() async throws {
        let w = try make()
        await present(w.palette)
        await type("pasta", w.palette)
        let chats = w.palette.items.filter { $0.group == .chats }
        #expect(chats.map(\.id) == ["chat.\(w.chats["pasta"]!)", "chat.\(w.chats["tax"]!)"])
        #expect(chats.first?.titleMatched == true)
    }

    @Test func activatingAChatOpensIt() async throws {
        let w = try make()
        await present(w.palette)
        await type("garden", w.palette)
        let row = try #require(w.palette.items.first { $0.group == .chats })
        w.palette.activate(row.id)
        w.palette.hostDismiss()  // the vendored view dismisses after onActivate
        #expect(w.state.route == .chat(w.chats["garden"]!))
        #expect(!w.palette.isPresented)
    }

    @Test func noMatchesLeavesNoRows() async throws {
        let w = try make()
        await present(w.palette)
        await type("qwxzvb", w.palette)
        #expect(w.palette.items.isEmpty)
        #expect(w.palette.candidates.isEmpty)
    }

    // MARK: AC2 actions + settings rows

    @Test func actionsTabListsTheRequiredActions() async throws {
        let w = try make()
        await present(w.palette, tab: .actions)
        let titles = w.palette.items.map(\.title)
        #expect(titles.contains("New chat"))
        #expect(titles.contains("New incognito chat"))
        #expect(titles.contains("Switch chat"))
        for section in SettingsSection.allCases {
            #expect(w.palette.items.contains { $0.kind == .action(.openSettings(section)) })
        }
        #expect(w.palette.items.allSatisfy { $0.group == .actions })
        // Actions carry no category tag (the tab already says what they are).
        #expect(w.palette.candidates.allSatisfy { $0.category == nil })
    }

    @Test func sendWithFindsTheGeneralRowAndOpensSettingsThere() async throws {
        let w = try make()
        var opened: [(SettingsSection, String?)] = []
        w.palette.attach(service: w.state.service, handlers: PaletteHandlers(openSettings: { opened.append(($0, $1)) }))
        await present(w.palette)
        await type("send with", w.palette)
        let row = try #require(w.palette.items.first { $0.group == .settings })
        #expect(row.title == "Send with")
        #expect(row.subtitle == "General")
        #expect(w.palette.items.filter { $0.group == .actions }.isEmpty)
        w.palette.activate(row.id)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == .general)
        #expect(opened.first?.1 == "sendWithCommandEnter")
    }

    @Test func windowHandlersRecordTheSettingsRequest() async throws {
        let w = try make()
        await present(w.palette, tab: .settings)
        await type("plain", w.palette)
        let before = SettingsNavigator.shared.requestCount
        let row = try #require(w.palette.items.first)
        w.palette.activate(row.id)
        #expect(SettingsNavigator.shared.requestCount == before + 1)
        #expect(SettingsNavigator.shared.pending == .init(section: .general, rowID: "plainTextComposer"))
        _ = SettingsNavigator.shared.take()
    }

    @Test func switchChatKeepsThePaletteOpenOnTheChatsTab() async throws {
        let w = try make()
        await present(w.palette, tab: .actions)
        let row = try #require(w.palette.items.first { $0.kind == .action(.switchChat) })
        let g = w.palette.resultGeneration
        w.palette.activate(row.id)
        w.palette.hostDismiss()
        await settle(w.palette, after: g)
        #expect(w.palette.isPresented)
        #expect(w.palette.tab == .chats)
        #expect(w.palette.items.count == 3)
        #expect(w.palette.items.allSatisfy { $0.group == .chats })
    }

    @Test func newChatActionStartsANewChat() async throws {
        let w = try make()
        w.state.open(.chat(w.chats["tax"]!))
        await present(w.palette)
        await type("new chat", w.palette)
        let row = try #require(w.palette.items.first)
        #expect(row.kind == .action(.newChat))
        w.palette.activate(row.id)
        #expect(w.state.route == .newChat)
    }

    // MARK: AC3 Tab + Escape

    @Test func tabAsksTheQueryInANewChat() async throws {
        let w = try make()
        w.state.open(.chat(w.chats["tax"]!))
        await present(w.palette)
        await type("how do tides work", w.palette)
        #expect(w.palette.askInNewChat(w.palette.query))
        #expect(w.state.route == .newChat)
        #expect(w.state.composerText == "how do tides work")
        #expect(try w.state.service.transcript(w.chats["tax"]!).count == 2)  // nothing was sent
        #expect(!w.palette.isPresented)
    }

    @Test func tabWithAnEmptyQueryDoesNothingButIsConsumed() async throws {
        let w = try make()
        await present(w.palette)
        #expect(w.palette.askInNewChat("  "))
        #expect(w.palette.isPresented)
        #expect(w.state.composerText.isEmpty)
    }

    @Test func escapeCloses() async throws {
        let w = try make()
        await present(w.palette)
        w.palette.hostDismiss()
        #expect(!w.palette.isPresented)
        w.palette.toggle()
        #expect(w.palette.isPresented)
        w.palette.toggle()
        #expect(!w.palette.isPresented)
    }

    // MARK: Liked filter (AT-005 leg 4, ⌘K half)

    @Test func likedFilterListsLikedReplies() async throws {
        let w = try make()
        try FeedbackRepository(w.env.database).setRating(w.replies["tax"]!, .liked)
        await present(w.palette)
        let g = w.palette.resultGeneration
        w.palette.setLikedOnly(true)
        await settle(w.palette, after: g)
        #expect(w.palette.items.map(\.id) == ["chat.\(w.chats["tax"]!)"])
        #expect(w.palette.items.first?.kind == .chat(w.chats["tax"]!, messageID: w.replies["tax"]!))
        await type("pasta", w.palette)
        #expect(w.palette.items.map(\.id) == ["chat.\(w.chats["tax"]!)"])
        await type("zebracorn", w.palette)
        #expect(w.palette.items.isEmpty)
    }

    // MARK: Fuzzy matching of actions and rows

    @Test func shortQueriesMatchLooselyLongOnesBySubstring() {
        #expect(PaletteMatch.score("nc", fields: ["New chat"]) != nil)
        #expect(PaletteMatch.score("send with", fields: ["Toggle sidebar"]) == nil)
        #expect(PaletteMatch.score("sidebar", fields: ["Toggle Sidebar"]) != nil)
        #expect(PaletteMatch.score("", fields: ["anything"]) == 0)
    }
}
