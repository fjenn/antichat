// AT-012 (M1.T11, R-012) controller legs of the chat search: New chat + recents, ranking order into the vendored
// view, activation, Tab = ask in a new chat, Escape. The window-level
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

    private func present(_ p: PaletteController) async {
        let g = p.resultGeneration
        p.present()
        await settle(p, after: g)
    }

    // MARK: AC1 tabs + search

    @Test func emptyQueryShowsNewChatThenRecents() async throws {
        let w = try make()
        await present(w.palette)
        #expect(w.palette.isPresented)
        #expect(w.palette.items.map(\.kind).first == .newChat)
        #expect(w.palette.items.dropFirst().map(\.id).sorted() == w.chats.values.map { "chat.\($0)" }.sorted())
        // The vendored view gets the same rows in the same order, with no group headers.
        #expect(w.palette.candidates.map(\.id) == w.palette.items.map(\.id))
        #expect(w.palette.candidates.allSatisfy { $0.category == nil })
    }

    @Test func bodyOnlyTokenFindsItsChat() async throws {
        let w = try make()
        await present(w.palette)
        await type("zebracorn", w.palette)
        let chats = w.palette.items.filter(\.isChat)
        #expect(chats.map(\.id) == ["chat.\(w.chats["garden"]!)"])
        let excerpt = try #require(chats.first?.excerpt)
        #expect(excerpt.contains { $0.isMatch && $0.text.lowercased() == "zebracorn" })
    }

    /// Q-015 r7 (J09): the recents never stand in for a query's matches while its search is pending (J09 counted the
    /// 8 recents under "zebracorn"; Return in that window opened a recent chat).
    @Test func typingDropsTheRecentsBeforeTheSearchReturns() async throws {
        let w = try make()
        await present(w.palette)
        #expect(w.palette.items.contains(where: { $0.isChat }))
        let g = w.palette.resultGeneration
        w.palette.queryDidChange("zebracorn")
        #expect(!w.palette.items.contains(where: { $0.isChat }))  // synchronously, before the debounced search
        await settle(w.palette, after: g)
        #expect(w.palette.items.filter(\.isChat).map(\.id) == ["chat.\(w.chats["garden"]!)"])
        // A refined query keeps the previous query's matches until its own arrive.
        w.palette.queryDidChange("zebracorn ")
        #expect(w.palette.items.filter(\.isChat).map(\.id) == ["chat.\(w.chats["garden"]!)"])
    }

    @Test func titleWordFindsItsChatFirst() async throws {
        let w = try make()
        await present(w.palette)
        await type("pasta", w.palette)
        let chats = w.palette.items.filter(\.isChat)
        #expect(chats.map(\.id) == ["chat.\(w.chats["pasta"]!)", "chat.\(w.chats["tax"]!)"])
        #expect(chats.first?.titleMatched == true)
    }

    @Test func activatingAChatOpensIt() async throws {
        let w = try make()
        await present(w.palette)
        await type("garden", w.palette)
        let row = try #require(w.palette.items.first(where: { $0.isChat }))
        w.palette.activate(row.id)
        w.palette.hostDismiss()  // the vendored view dismisses after onActivate
        #expect(w.state.route == .chat(w.chats["garden"]!))
        #expect(!w.palette.isPresented)
    }

    /// A snippet reads as plain text (no `**`, table pipes or rules); the match stays marked.
    @Test func snippetsArePlainText() {
        let runs = ChatsProvider.plain([.init(text: "| :--- | **Red ", isMatch: false), .init(text: "fox", isMatch: true),
                                        .init(text: "** in `snow`", isMatch: false)])
        #expect(runs.map(\.text).joined() == "Red fox in snow")
        #expect(runs.filter(\.isMatch).map(\.text) == ["fox"])
    }

    @Test func noMatchesLeavesNoRows() async throws {
        let w = try make()
        await present(w.palette)
        await type("qwxzvb", w.palette)
        #expect(w.palette.items.isEmpty)
        #expect(w.palette.candidates.isEmpty)
    }

    @Test func newChatActionStartsANewChat() async throws {
        let w = try make()
        w.state.open(.chat(w.chats["tax"]!))
        await present(w.palette)
        let row = try #require(w.palette.items.first)
        #expect(row.kind == .newChat && row.title == "New chat")
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

    // MARK: Fuzzy matching of settings rows (the Settings search)

    @Test func shortQueriesMatchLooselyLongOnesBySubstring() {
        #expect(PaletteMatch.score("nc", fields: ["New chat"]) != nil)
        #expect(PaletteMatch.score("send with", fields: ["Toggle sidebar"]) == nil)
        #expect(PaletteMatch.score("sidebar", fields: ["Toggle Sidebar"]) != nil)
        #expect(PaletteMatch.score("", fields: ["anything"]) == 0)
    }
}

private extension PaletteItem {
    var isChat: Bool { if case .chat = kind { true } else { false } }
}
