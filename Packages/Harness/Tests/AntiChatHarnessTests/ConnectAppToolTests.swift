// Connecting an app from a chat (ConnectAppTool): the plain "log into GitHub" message shows the Connect card without
// the model; a `connect_app` call ends the turn with the card; and with apps connected the turn keeps Composio's
// search + execute tools offered and names the apps in the prompt (the "Gmail is connected but the model says it
// cannot read my email" report).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ConnectAppToolTests {
    @Test(arguments: [
        ("Let me log into GitHub", "github"), ("connect my gmail", "gmail"), ("sign in to slack", "slack"),
        ("Can you connect to my Google Calendar account please?", "googlecalendar"), ("login to notion.", "notion"),
        ("I want to link my Outlook", "outlook"),
        ("sign in to Trello", "trello"),  // any app of the bundled catalogue, by its exact name
    ])
    func plainRequestsShowTheCard(text: String, toolkit: String) {
        #expect(ConnectAppTool.directRequest(text) == toolkit)
    }

    @Test(arguments: [
        "connect the dots for me", "log in", "connect github and slack", "how do I log into github from the terminal?",
        "summarise my latest emails", "connect to my company VPN", "sign in to Frobnicate", "write a linear regression",
    ])
    func anythingElseGoesToTheModel(text: String) {
        #expect(ConnectAppTool.directRequest(text) == nil)
    }

    @Test func appNamesResolveToToolkits() {
        #expect(ComposioApps.resolve("GitHub") == "github")
        #expect(ComposioApps.resolve("my Gmail account") == "gmail")
        #expect(ComposioApps.resolve("email") == "gmail")
        #expect(ComposioApps.resolve("Google Calendar") == "googlecalendar")
        #expect(ComposioApps.resolve("Trello", offered: ComposioApps.defaults) == "trello")  // the catalogue knows it
        #expect(ComposioApps.resolve("Frobnicate", offered: ComposioApps.defaults) == nil)
        #expect(ComposioApps.resolve("Frobnicate", offered: ["frobnicate"]) == "frobnicate")
    }

    @Test func connectedAppKeepsItsToolsOfferedAndIsNamed() {
        // Small tier: only when the message (or the one before) is about a connected app.
        let p = ConnectAppTool.plan(userTexts: ["what's in my inbox today?"], connected: ["gmail"], connectOffered: true,
                                    hasComposio: true, roomy: false)
        #expect(p.pinsComposio && !p.pinsConnect && p.apps == ["Gmail"])
        let followUp = ConnectAppTool.plan(userTexts: ["check my gmail", "reply to the second one"], connected: ["gmail"],
                                           connectOffered: true, hasComposio: true, roomy: false)
        #expect(followUp.pinsComposio)
        let other = ConnectAppTool.plan(userTexts: ["what is 2 + 2"], connected: ["gmail"], connectOffered: true,
                                        hasComposio: true, roomy: false)
        #expect(!other.pinsComposio && other.apps == ["Gmail"])
        // "send an email to …" names no app and says no "my": the connected mail app's tools still stay offered.
        #expect(ConnectAppTool.plan(userTexts: ["Now send test@example.com an email saying hi"], connected: ["gmail"],
                                    connectOffered: true, hasComposio: true, roomy: false).pinsComposio)
        let send = ConnectAppTool.plan(userTexts: ["Send another email to test@example.com"], connected: ["gmail"],
                                       connectOffered: true, hasComposio: true, roomy: false)
        #expect(send.wanted == ["Gmail"])
        #expect(ConnectAppTool.turnLine(wanted: send.wanted, search: "s", execute: "e", offered: ["s", "e"])?.contains("Gmail is connected") == true)
        #expect(ConnectAppTool.turnLine(wanted: send.wanted, search: "s", execute: "e", offered: ["find_tools"]) == nil)
        #expect(ConnectAppTool.refusesAccess("I cannot send emails directly. I can help you draft one.")
                && !ConnectAppTool.refusesAccess("Here is a draft:\n\nHi team, …"))
        // A roomy tier always keeps the pair.
        #expect(ConnectAppTool.plan(userTexts: ["what is 2 + 2"], connected: ["gmail"], connectOffered: true,
                                    hasComposio: true, roomy: true).pinsComposio)
        // Nothing connected: nothing pinned, nothing said.
        let none = ConnectAppTool.plan(userTexts: ["hello there"], connected: [], connectOffered: true, hasComposio: true, roomy: true)
        #expect(none == ConnectAppTool.Plan())
    }

    @Test func missingAppKeepsConnectOffered() {
        func pins(_ text: String, connected: Set<String> = []) -> Bool {
            ConnectAppTool.plan(userTexts: [text], connected: connected, connectOffered: true, hasComposio: false, roomy: false).pinsConnect
        }
        #expect(pins("summarise my latest emails"))  // needs Gmail / Outlook, none connected
        #expect(pins("open an issue on github about the crash"))
        #expect(pins("can you sign in to my bank for me"))  // talks about signing in: the model decides
        #expect(!pins("summarise my latest emails", connected: ["gmail"]))
        #expect(!pins("write an email to my boss about the delay"))  // drafting needs no app
        #expect(!pins("what is the capital of France"))
    }

    @Test func clauseSaysHowForWhatIsOffered() {
        let both = ConnectAppTool.clause(apps: ["Gmail", "GitHub"], search: "c_search", execute: "c_exec",
                                         offered: ["c_exec", "c_search", "get_time"])
        #expect(both?.contains("Gmail, GitHub") == true && both?.contains("call c_search") == true && both?.contains("c_exec") == true)
        let viaFind = ConnectAppTool.clause(apps: ["Gmail"], search: "c_search", execute: "c_exec", offered: ["get_time", "find_tools"])
        #expect(viaFind?.contains("find_tools") == true)
        #expect(ConnectAppTool.clause(apps: ["Gmail"], search: "c_search", execute: "c_exec", offered: []) == nil)
        #expect(ConnectAppTool.clause(apps: [], search: "c_search", execute: "c_exec", offered: ["c_search", "c_exec"]) == nil)
    }

    /// The smallest tier (3 tools per step) with a dozen eligible tools still offers the pinned pair.
    @Test func pinnedPairSurvivesTheSmallestTier() {
        let names = (1...10).map { "tool_\($0)" } + ["get_time", "composio_composio_search_tools", "composio_composio_multi_execute_tool"]
        let eligible = names.map { ToolSchema(name: $0, description: "Does \($0).", parametersJSON: #"{"type":"object","properties":{}}"#) }
        let sel = ToolSelector.select(eligible: eligible, forced: ["composio_composio_search_tools", "composio_composio_multi_execute_tool"],
                                      tier: .t0, budget: .forTier(.t0))
        #expect(Set(sel.tools.map(\.name)) == ["composio_composio_search_tools", "composio_composio_multi_execute_tool", FindToolsTool.name])
    }

    @Test func descriptionFitsThePromptsOneLine() {
        #expect(ToolBlockRenderer.oneLineToolDescription(ConnectAppTool.description) == ConnectAppTool.description)
    }

    // MARK: Using a connected app

    @Test func executeResultsAlwaysComeBackInline() throws {
        let sent = SlugPermission.executeArguments(#"{"tools":[{"tool_slug":"GMAIL_FETCH_EMAILS","arguments":{}}],"sync_response_to_workbench":true}"#)
        let o = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(o["sync_response_to_workbench"] as? Bool == false && (o["tools"] as? [Any])?.count == 1)
        let added = SlugPermission.executeArguments(#"{"tools":[]}"#)
        #expect(added.contains(#""sync_response_to_workbench":false"#))
        #expect(!SlugPermission.executeParametersJSON.contains("workbench"))
        #expect((try? JSONSerialization.jsonObject(with: Data(SlugPermission.executeParametersJSON.utf8))) != nil)
    }

    @Test func remoteCodeSlugsNeverRun() {
        for s in ["COMPOSIO_REMOTE_WORKBENCH", "COMPOSIO_REMOTE_BASH_TOOL", "PYTHON_EXECUTE", "CODEINTERPRETER_RUN"] {
            #expect(SlugPermission.isRemoteExecution(s))
        }
        for s in ["GMAIL_FETCH_EMAILS", "GMAIL_SEND_EMAIL", "GITHUB_LIST_REPOSITORIES"] { #expect(!SlugPermission.isRemoteExecution(s)) }
    }

    @Test func readsRunAndWritesAskAlsoAfterUntrustedResults() {
        let checks = SlugPermission.checks(slugs: ["GMAIL_FETCH_EMAILS", "GMAIL_SEND_EMAIL"], cache: .init(), untrustedContext: true) { _ in nil }
        #expect(checks[0].decision == .run)
        #expect(checks[1].decision == .ask(untrusted: true))
    }

    @Test func unknownVerbsAskUnlessTaggedOrARead() {
        let cache = SlugPermission.TagCache()
        func asks(_ slug: String) -> Bool { SlugPermission.isWrite(slug, hints: cache.hints(slug)) }
        for s in ["GITHUB_RETRIEVE_ISSUE", "SLACK_VIEW_CHANNEL", "NOTION_QUERY_DATABASE", "GOOGLEDRIVE_DOWNLOAD_FILE", "GMAIL_COUNT_UNREAD"] {
            #expect(!asks(s))
        }
        for s in ["GMAIL_SEND_EMAIL", "NOTION_DUPLICATE_PAGE", "GITHUB_STAR_REPOSITORY", "GMAIL_DELETE_MESSAGE", "SLACK_UPDATE_AND_GET_MESSAGE"] {
            #expect(asks(s))
        }
        cache.learn(fromResult: #"{"tools":[{"tool_slug":"NOTION_DUPLICATE_PAGE","tags":["createHint"]},{"slug":"GITHUB_STAR_REPOSITORY","annotations":{"readOnlyHint":true}}]}"#)
        #expect(asks("NOTION_DUPLICATE_PAGE") && !asks("GITHUB_STAR_REPOSITORY"))
    }

    @Test func slugsReadAsAppAndAction() {
        #expect(SlugPermission.display("GMAIL_SEND_EMAIL") == ("Gmail", "Send email"))
        #expect(SlugPermission.display("GOOGLECALENDAR_CREATE_EVENT") == ("Google Calendar", "Create event"))
        let args = SlugPermission.innerArguments(
            #"{"sync_response_to_workbench":false,"tools":[{"tool_slug":"GMAIL_SEND_EMAIL","arguments":{"to":"a@example.com","subject":"Hi"}}]}"#,
            slug: "GMAIL_SEND_EMAIL")
        #expect(args.contains("a@example.com") && !args.contains("workbench"))
    }

    @Test func largeResultKeepsEveryItemShortened() throws {
        let items = (1...20).map { i in
            ["sender": "person\(i)@example.com", "subject": "Subject \(i)", "messageTimestamp": "2026-01-\(i)",
             "messageText": String(repeating: "word ", count: 3000), "payload": ["raw": String(repeating: "x", count: 20000)]] as [String: Any]
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["data": ["messages": items]]), as: UTF8.self)
        let out = MCPToolProxy.compactJSON(text, capChars: 16000)
        #expect(out.count <= 16000 && !out.contains("payload"))
        for i in 1...20 { #expect(out.contains("Subject \(i)\"") && out.contains("person\(i)@example.com")) }
        #expect(MCPToolProxy.compactJSON(#"{"a":1}"#, capChars: 100) == #"{"a":1}"#)
    }

    @Test func announcedButUncalledToolUseIsNoticed() {
        #expect(ConnectAppTool.announcesToolUse("I need to find the appropriate tool. Let me search for it.\n\nNow I'll send the email."))
        #expect(!ConnectAppTool.announcesToolUse("Paris is the capital of France."))
        #expect(!ConnectAppTool.announcesToolUse("Here is a draft you can send:\n\nHi team, the report is attached."))
    }

    // MARK: Turns

    func controller(_ engine: any EngineService, connectApps: Bool = true) async throws -> (TurnController, UpdateLog) {
        let db = try AppDatabase.inMemory()
        var rt = ToolRuntime(registry: ToolRegistry(RouterStubs.all), permissions: ToolPermissionStore(db), policy: .forTier(.t1),
                             selection: .standard, router: try await RouterStubs.router(enabled: false), tier: { .t1 })
        rt.connectApps = connectApps
        rt.onlineGate = OnlineToolGate(policy: NetworkPolicyStore(defaults: .inMemory()),
                                       path: PathStatus(fake: "ok"))
        let c = TurnController(chatID: StorageID.make(), database: db, engine: engine, tools: rt) { .scripted("inline") }
        return (c, UpdateLog(c))
    }

    func cards(_ log: UpdateLog, _ id: String) -> [ConnectAppTool.Card] {
        log.all.filter { $0.assistantID == id }.compactMap { u in
            if case .activity(let a) = u.kind { ConnectAppTool.card(a) } else { nil }
        }
    }

    @Test func plainRequestIsAnsweredByTheCardNotTheModel() async throws {
        let engine = TextOnlyEngine()
        let (c, log) = try await controller(engine)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "Let me log into GitHub", parentID: nil), assistantID: a)
        let res = try await log.waitFinished(a)
        #expect(engine.requests.withLock { $0.count } == 0)
        #expect(res.status == .done && res.text.isEmpty)
        #expect(cards(log, a) == [.init(toolkit: "github", name: "GitHub", direct: true)])
    }

    @Test func withoutARelayTheMessageGoesToTheModel() async throws {
        let engine = TextOnlyEngine()
        let (c, log) = try await controller(engine, connectApps: false)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "Let me log into GitHub", parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a)
        #expect(engine.requests.withLock { $0.count } == 1 && cards(log, a).isEmpty)
    }

    @Test func connectAppCallEndsTheTurnWithTheCard() async throws {
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"connect_app","args":"{\\"app\\":\\"GitHub\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"I cannot access GitHub.","delayMs":1}
            """
        let engine = CountingEngine(InProcessScriptedEngine(script: try EngineScript(text: script)))
        let (c, log) = try await controller(engine)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "open an issue on github about the crash", parentID: nil), assistantID: a)
        let res = try await log.waitFinished(a)
        #expect(engine.count.withLock { $0 } == 1)  // no text step after the card
        #expect(res.status == .done)
        #expect(cards(log, a).last == .init(toolkit: "github", name: "GitHub", direct: false))
        // GitHub named with nothing connected: connect_app was in the offered set on a four-tool tier.
        #expect(await c.lastPrompt?.tools.contains { $0.name == ConnectAppTool.name } == true)
    }
}
